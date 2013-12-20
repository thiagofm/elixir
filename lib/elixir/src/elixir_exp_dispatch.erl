%% Helpers related to dispatching to imports and references.
%% This module access the information stored on the scope
%% by elixir_import and therefore assumes it is normalized (ordsets)
-module(elixir_exp_dispatch).
-export([find_import/4, dispatch_import/5, dispatch_require/6, format_error/1]).
-include("elixir.hrl").
-import(ordsets, [is_element/2]).
-define(builtin, 'Elixir.Kernel').

find_import(Meta, Name, Arity, E) ->
  Tuple = { Name, Arity },

  case find_dispatch(Meta, Tuple, [], E) of
    { function, Receiver } ->
      elixir_lexical:record_import(Receiver, E#elixir_env.lexical_tracker),
      elixir_tracker:record_import(Tuple, Receiver, E#elixir_env.module, E#elixir_env.function),
      Receiver;
    { macro, Receiver } ->
      elixir_lexical:record_import(Receiver, E#elixir_env.lexical_tracker),
      elixir_tracker:record_import(Tuple, Receiver, E#elixir_env.module, E#elixir_env.function),
      Receiver;
    _ ->
      false
  end.

%% Dispatches

dispatch_import(Meta, Name, Args, E, Callback) ->
  case expand_import(Meta, { Name, length(Args) }, Args, E, []) of
    { ok, Receiver, Tree } ->
      translate_expansion(Meta, Receiver, Tree, E);
    { ok, Receiver } ->
      elixir_exp:expand({ { '.', [], [Receiver, Name] }, Meta, Args }, E);
    error ->
      Callback()
  end.

dispatch_require(Meta, Receiver, Name, Args, E, Callback) when is_atom(Receiver) ->
  Arity = length(Args),
  Tuple = { Name, Arity },

  case (Receiver == ?builtin) andalso is_element(Tuple, in_erlang_functions()) of
    true  -> Callback(erlang);
    false ->
      case expand_require(Meta, Receiver, Tuple, Args, E) of
        { ok, Receiver, Tree } -> translate_expansion(Meta, Receiver, Tree, E);
        error -> Callback(Receiver)
      end
  end;

dispatch_require(_Meta, Receiver, _Name, _Args, _E, Callback) ->
  Callback(Receiver).

%% Macros expansion

expand_import(Meta, { Name, Arity } = Tuple, Args, E, Extra) ->
  Module   = E#elixir_env.module,
  Dispatch = find_dispatch(Meta, Tuple, Extra, E),
  Function = E#elixir_env.function,
  Local    = (Function /= nil) andalso (Function /= Tuple) andalso
              elixir_def_local:macro_for(Module, Name, Arity),

  case Dispatch of
    %% In case it is an import, or the receive is the same as the
    %% current module (happens in bootstraping), we dispatch the import.
    { Kind, Receiver } when Kind == import; Receiver == Module ->
      do_expand_import(Meta, Tuple, Args, Module, E, Dispatch);

    %% There is a local and an import. This is a conflict.
    { _, Receiver } when Local /= false ->
      Error = { macro_conflict, { Receiver, Name, Arity } },
      elixir_errors:form_error(Meta, E#elixir_env.file, ?MODULE, Error);

    %% There is no local. Dispatch the import.
    _ when Local == false ->
      do_expand_import(Meta, Tuple, Args, Module, E, Dispatch);

    %% Dispatch to the local.
    _ ->
      elixir_tracker:record_local(Tuple, Module, Function),
      { ok, Module, expand_macro_fun(Meta, Local(), Module, Name, Args, Module, E) }
  end.

do_expand_import(Meta, { Name, Arity } = Tuple, Args, Module, E, Result) ->
  case Result of
    { function, Receiver } ->
      elixir_lexical:record_import(Receiver, E#elixir_env.lexical_tracker),
      elixir_tracker:record_import(Tuple, Receiver, Module, E#elixir_env.function),
      Endpoint = case (Receiver == ?builtin) andalso is_element(Tuple, in_erlang_functions()) of
        true  -> erlang;
        false -> Receiver
      end,
      { ok, Endpoint };
    { macro, Receiver } ->
      elixir_lexical:record_import(Receiver, E#elixir_env.lexical_tracker),
      elixir_tracker:record_import(Tuple, Receiver, Module, E#elixir_env.function),
      { ok, Receiver, expand_macro_named(Meta, Receiver, Name, Arity, Args, Module, E) };
    { import, Receiver } ->
      case expand_require([{require,false}|Meta], Receiver, Tuple, Args, E) of
        { ok, _, _ } = Response -> Response;
        error -> { ok, Receiver }
      end;
    false ->
      error
  end.

expand_require(Meta, Receiver, { Name, Arity } = Tuple, Args, E) ->
  Module   = E#elixir_env.module,
  Function = E#elixir_env.function,

  case is_element(Tuple, get_optional_macros(Receiver)) of
    true  ->
      elixir_lexical:record_remote(Receiver, E#elixir_env.lexical_tracker),
      elixir_tracker:record_remote(Tuple, Receiver, Module, Function),
      { ok, Receiver, expand_macro_named(Meta, Receiver, Name, Arity, Args, Module, E) };
    false -> error
  end.

%% Expansion helpers

expand_macro_fun(Meta, Fun, Receiver, Name, Args, Module, E) ->
  Requires = E#elixir_env.requires,
  case (Receiver == Module) or is_element(Receiver, Requires) or skip_require(Meta) of
    true  -> ok;
    false ->
      Tuple = { unrequired_module, { Receiver, Name, length(Args), Requires } },
      elixir_errors:form_error(Meta, E#elixir_env.file, ?MODULE, Tuple)
  end,

  Line = ?line(Meta),
  EArg = #elixir_env{line=Line},

  try
    apply(Fun, [EArg|Args])
  catch
    Kind:Reason ->
      Info = { Receiver, Name, length(Args), location(Line, E) },
      erlang:raise(Kind, Reason, prune_stacktrace(Info, erlang:get_stacktrace(), EArg))
  end.

expand_macro_named(Meta, Receiver, Name, Arity, Args, Module, E) ->
  ProperName  = ?elixir_macro(Name),
  ProperArity = Arity + 1,
  Fun         = fun Receiver:ProperName/ProperArity,
  expand_macro_fun(Meta, Fun, Receiver, Name, Args, Module, E).

translate_expansion(Meta, Receiver, Tree, E) ->
  Line = ?line(Meta),
  New  = E#elixir_env.macro_counter + 1,

  try
    elixir_exp:expand(
      elixir_quote:linify_with_context_counter(Line, { Receiver, New }, Tree),
      E#elixir_env{macro_counter=New}
    )
  catch
    Kind:Reason ->
      erlang:raise(Kind, Reason, prune_stacktrace(mfa(Line, E), erlang:get_stacktrace(), nil))
  end.

mfa(Line, #elixir_env{module=nil} = E) ->
  { elixir_compiler, '__FILE__', 2, location(Line, E) };
mfa(Line, #elixir_env{module=Module, function=nil} = E) ->
  { Module, '__MODULE__', 0, location(Line, E) };
mfa(Line, #elixir_env{module=Module, function={ Name, Arity }} = E) ->
  { Module, Name, Arity, location(Line, E) }.

location(Line, E) ->
  [{ file, E#elixir_env.file }, { line, Line }].

%% Helpers

skip_require(Meta) ->
  lists:keyfind(require, 1, Meta) == { require, false }.

find_dispatch(Meta, Tuple, Extra, E) ->
  case is_import(Meta) of
    { import, _ } = Import ->
      Import;
    false ->
      Funs = E#elixir_env.functions,
      Macs = Extra ++ E#elixir_env.macros,
      FunMatch = find_dispatch(Tuple, Funs),
      MacMatch = find_dispatch(Tuple, Macs),

      case { FunMatch, MacMatch } of
        { [], [Receiver] } -> { macro, Receiver };
        { [Receiver], [] } -> { function, Receiver };
        { [], [] } -> false;
        _ ->
          { Name, Arity } = Tuple,
          [First, Second|_] = FunMatch ++ MacMatch,
          Error = { ambiguous_call, { First, Second, Name, Arity } },
          elixir_errors:form_error(Meta, E#elixir_env.file, ?MODULE, Error)
      end
  end.

find_dispatch(Tuple, List) ->
  [Receiver || { Receiver, Set } <- List, is_element(Tuple, Set)].

is_import(Meta) ->
  case lists:keyfind(import, 1, Meta) of
    { import, _ } = Import ->
      case lists:keyfind(context, 1, Meta) of
        { context, _ } -> Import;
        false ->
          false
      end;
    false ->
      false
  end.

%% We've reached the invoked macro, skip it with the rest
prune_stacktrace(Info, [{ _, _, [E|_], _ }|_], E) ->
  [Info];
%% We've reached the elixir_dispatch internals, skip it with the rest
prune_stacktrace(Info, [{ elixir_dispatch, _, _, _ }|_], _) ->
  [Info];
prune_stacktrace(Info, [H|T], E) ->
  [H|prune_stacktrace(Info, T, E)];
prune_stacktrace(Info, [], _) ->
  [Info].

%% ERROR HANDLING

format_error({ unrequired_module, { Receiver, Name, Arity, _Required }}) ->
  Module = elixir_errors:inspect(Receiver),
  io_lib:format("you must require ~ts before invoking the macro ~ts.~ts/~B",
    [Module, Module, Name, Arity]);

format_error({ macro_conflict, { Receiver, Name, Arity } }) ->
  io_lib:format("call to local macro ~ts/~B conflicts with imported ~ts.~ts/~B, "
    "please rename the local macro or remove the conflicting import",
    [Name, Arity, elixir_errors:inspect(Receiver), Name, Arity]);

format_error({ ambiguous_call, { Mod1, Mod2, Name, Arity }}) ->
  io_lib:format("function ~ts/~B imported from both ~ts and ~ts, call is ambiguous",
    [Name, Arity, elixir_errors:inspect(Mod1), elixir_errors:inspect(Mod2)]).

%% INTROSPECTION

%% Do not try to get macros from Erlang. Speeds up compilation a bit.
get_optional_macros(erlang) -> [];

get_optional_macros(Receiver) ->
  case code:ensure_loaded(Receiver) of
    { module, Receiver } ->
      try
        Receiver:'__info__'(macros)
      catch
        error:undef -> []
      end;
    { error, _ } -> []
  end.

%% Functions imported from Erlang module. MUST BE SORTED.
%% TODO: Inline operators here as well once bug in erl_eval is fixed.
in_erlang_functions() ->
  [
    { abs, 1 },
    { apply, 2 },
    { apply, 3 },
    { atom_to_list, 1 },
    { binary_part, 3 },
    { binary_to_float, 1 },
    { binary_to_float, 2 },
    { binary_to_integer, 1 },
    { binary_to_integer, 2 },
    { binary_to_term, 1 },
    { binary_to_term, 2 },
    { bit_size, 1 },
    { bitstring_to_list, 1 },
    { byte_size, 1 },
    % { date, 0 },
    { exit, 1 },
    % { float, 1 },
    { float_to_binary, 1 },
    % { float_to_binary, 2 },
    { float_to_list, 1 },
    % { float_to_list, 2 },
    { hd, 1 },
    { integer_to_binary, 1 },
    { integer_to_binary, 2 },
    { integer_to_list, 1 },
    { integer_to_list, 2 },
    { iolist_size, 1 },
    { iolist_to_binary, 1 },
    { is_alive, 0 },
    { is_atom, 1 },
    { is_binary, 1 },
    { is_bitstring, 1 },
    { is_boolean, 1 },
    { is_float, 1 },
    { is_function, 1 },
    { is_function, 2 },
    { is_integer, 1 },
    { is_list, 1 },
    { is_number, 1 },
    { is_pid, 1 },
    { is_port, 1 },
    { is_reference, 1 },
    { is_tuple, 1 },
    { length, 1 },
    { list_to_atom, 1 },
    { list_to_bitstring, 1 },
    { list_to_existing_atom, 1 },
    { list_to_float, 1 },
    { list_to_integer, 1 },
    { list_to_integer, 2 },
    { list_to_tuple, 1 },
    { make_ref, 0 },
    { max, 2 },
    { min, 2 },
    { node, 0 },
    { node, 1 },
    % { now, 0 },
    { round, 1 },
    { self, 0 },
    { size, 1 },
    { spawn, 1 },
    { spawn, 3 },
    { spawn_link, 1 },
    { spawn_link, 3 },
    % { split_binary, 2 },
    { term_to_binary, 1 },
    { term_to_binary, 2 },
    { throw, 1 },
    % { time, 0 },
    { tl, 1 },
    { trunc, 1 },
    { tuple_size, 1 },
    { tuple_to_list, 1 }
  ].