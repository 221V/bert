-module(bert_google).
-export([parse_transform/2]).
-include("bert.hrl").

% mini prelude

c(K)      -> list_to_atom(binary_to_list(term_to_binary(K))).
tab(N)    -> bert:tab(N).
undup(X)  -> sets:to_list(sets:from_list(X)).
j(X)      -> lists:concat(X).
j(X,Y)    -> string:join(X,Y).
var(K)    -> application:get_env(bert,c(K),[]).
svar(K,V) -> application:set_env(bert,c(K),V).
ensure()  -> Dir = filename:join([?GOOGLE,var(module)]), filelib:ensure_dir(Dir++"/java/"), Dir.
any(M)    -> X = ["google","protobuf","Any"], svar({int,M}, [j(X,"/")] ++ var({int,M})), j(X,".").

% export

parse_transform(Forms, _O) ->
    lists:map(fun save/1,gen(Forms)),
    File = filename:join(ensure(),"1compile.sh"),
    file:write_file(File,<<"#!/bin/sh\n\nprotoc *.proto --java_out=java\n">>),
    file:change_mode(File, 8#764),
    Forms.

gen(Forms) ->
    svar({enums,[]}, []),
    lists:flatten([ form(F) || F <- Forms ]).

save({[],_}) -> [];
save({File,Bin}) ->
    io:format("Generated Protobuf Model: ~p~n",[File]),
    Imprint = "// Generated by https://github.com/synrc/bert\n"
              "// DO NOT EDIT\n\n", file:write_file(File,iolist_to_binary([Imprint,Bin])).

form({attribute,1,module,M}) -> svar(module,j([M])), {[],[]};
form({attribute,_,type,{Field,{type,_,union,Atoms},[]}}) ->
    bert:info(?MODULE,"TYPE: ~p~n",[{Field,Atoms}]),
    A = [ X || {_,_,X} <- Atoms ],
    svar({deps,Field},[]),
    File = filename:join([ensure(),atom_to_list(Field)++".proto"]),
    {File,[header(Field),enum(Field,[],A)]};
form({attribute,_,record,{List,T}}) ->
    bert:info(?MODULE,"RECORD: ~p~n",[{List,T}]),
    svar({deps,List},[]),
    case lists:member(List,var(disallowed)) of
         true -> [];
            _ -> class(List,T)
    end;
form(_X) ->
    bert:info(?MODULE,"UNKNOWN: ~p~n",[_X]),
    {[],[]}.

class(Msg,T) ->
    File = filename:join(ensure(),atom_to_list(Msg)++".proto"),
    Fields = [
    begin {Field,Type,_,Args} = case L of
          {_,{_,_,{atom,_,F},V},{_,_,_T,A}}    -> {F,_T,V, A};
          {_,{_,_,{atom,_,F}},  {type,_,_T,A}} -> {F,_T,[],A};
             {_,_,{atom,_,F},   {call,_,_,_}}  -> {F,binary,[],[]};
             {_,_,{atom,_,F},   {nil,_}}       -> {F,binary,[],[]};
             {_,_,{atom,_,F}}                  -> {F,atom,  [],[]};
             {_,_,{atom,_,F},   {S,_,V}}       -> {F,S,V,[]}
          end,
          bert:info(?MODULE,"DEBUG: ~p~n",[{Field,Type,Args}]),
          tab(1) ++ infer(Msg,Type,Args,atom_to_list(Field),lists:concat([Pos]))
    end || {L,Pos} <- lists:zip(T,lists:seq(1,length(T))) ],
    {File,[header(Msg),enums(),j(["message ",Msg," {\n",Fields,"}\n"])]}.

header(N) ->
    bert:info(?MODULE,"TRACE: ~p~n",[var({deps,N})]),
    Package   = case var(module) of []->[]; M -> "package " ++ M ++ ";\n\n" end,
    Internals = undup([j(["import \"",       I,".proto\";\n"]) || I <- var({int,N}) ]),
    Publics   = undup([j(["import public \"",I,".proto\";\n"]) || I <- var({deps,N}) , I/=N]),
    lists:concat(
  [ "syntax = \"proto3\";\n", Package, Internals,
    "option java_generic_services = true;\n",
    "option java_multiple_files = true;\n",
    "option java_package = \"", N, ".grpc\";\n"
    "option java_outer_classname = \"", N, "Cls\";\n", Publics, "\n" ]).

enums() -> j([ begin {_,F} = Name, Enums = var({enum,Name}),
                     enum(F,"Enum",Enums) end || Name <- var({enums,[]}) ]).

enum(F,Sfx,Enums) ->
    X = "enum " ++ j([F,Sfx]) ++ " {\n" ++
    [  tab(1) ++ j([Enum]) ++ " = " ++ j([Pos]) ++ ";\n" || {Pos,Enum}
        <- lists:zip(lists:seq(0,length(Enums)-1),Enums) ] ++ "}\n\n",
    case Enums of [] -> []; _ -> X end.

keyword(_M,list,[{type,_,atom,[]}])          -> "repeated " ++ any(_M);
keyword(_M,list,[{type,_,union,_}])          -> "repeated " ++ any(_M);
keyword(_M,list,[{type,_,record,[{_,_,N}]}]) -> svar({deps,_M}, [N] ++ var({deps,_M})), j(["repeated ", N]);
keyword(_M,list,[{user_type,_,N,[]}])        -> svar({deps,_M}, [N] ++ var({deps,_M})), j(["repeated ", N]);
keyword(_M,record,[{atom,_,N}])              -> svar({deps,_M}, [N] ++ var({deps,_M})), j([N]);
keyword(_M,list,  [{type,_,integer,[]}])     -> "repeated int64";
keyword(_M,list,_)                           -> "repeated " ++ any(_M);
keyword(_M,term,_)    -> "bytes";
keyword(_M,integer,_) -> "int64";
keyword(_M,boolean,_) -> "bool";
keyword(_M,atom,_)    -> "string";
keyword(_M,binary,_)  -> "string";
keyword(_M,union,_)   -> "oneof";
keyword(_M,nil,_)     -> "bytes";
keyword(_M,N,_)       -> svar({deps,_M}, [N] ++ var({deps,_M})), j([N]).

% Message Field Args Pos Name Rest X

infer(_,[],_,_,_) -> [];
infer(M,union,[{type,_,nil,_},{type,_,record,X}],F,P) -> infer(M,record,X,F,P);
infer(M,union,[{type,_,nil,_},{type,_,N,_}=X],F,P)    -> infer(M,N,X,F,P);
infer(M,union,T,F,P) ->
    A = [ O || {_,_,J,_} = O <- T, J /= nil ],
    {Atoms,Rest} = lists:partition(fun ({atom,_,_,_}) -> true; (_) -> false end, A),
    svar({enum,{M,F}}, [ X || {_,_,X,_} <- Atoms ]),
    svar({enums,[]},        [{M,F}] ++ var({enums,[]})),
    bert:info(?MODULE,"INFER: ~p~n",[{M,F,Atoms,Rest}]),
    case {Atoms,Rest} of
         {[],_}             -> simple(M,A,{F,A,P});
         {_,[{_,_,nil,[]}]} -> F ++ "Enum " ++ F ++ " = " ++ P ++ ";\n";
         {_,[]}             -> F ++ "Enum " ++ F ++ " = " ++ P ++ ";\n";
                          _ -> simple(M,A,{F,A,P})  end;

infer(Message,Type,Args,Field,Pos)  ->
    lists:concat([keyword(Message,Type,Args)," ",Field," = ",lists:concat([Pos]),";\n"]).

foldr(_,[],{_,_,_},_) -> [];
foldr(M,[{type,_,nil,_}|R],{F,A,P},X) -> foldr(M,R,{A,F,P},X);
foldr(M,[{type,_,record,[{atom,_,N}]}|R],{F,A,P},X) ->
    [{infer(M,N, A,j([F,P,X]),j([P,X]))}] ++ foldr(M,R,{F,A,P},X+1);
foldr(M,[{type,_,T,_A}],{F,_,P},X) -> [{infer(M,T,_A,j([F,P,X]),j([P,X]))}];
foldr(M,[{type,_,T,_A}|R],{F,A,P},X) ->
    [{infer(M,T,_A,j([F,P,X]),j([P,X]))}] ++ foldr(M,R,{F,A,P},X+1).

simple(M,T,{F,A,P}) ->
    Fold = foldr(M,T,{F,A,P},0),
    case length(Fold) of
         1 -> [{J}] = Fold, J;
         _ -> bert:info(?MODULE,"FOLD ~p: ~p~n",[M,Fold]),
              j(["oneof ",F," {\n",j(lists:map(fun({X})->tab(2)++X end,Fold)),tab(1),"}\n"]) end.
