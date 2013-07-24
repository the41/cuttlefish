%% -------------------------------------------------------------------
%%
%% bjorn_schema: slurps schema files
%%
%% Copyright (c) 2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(bjorn_schema).

-export([file/1, map/3]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).
-endif.

%% TODO: temporary
-compile(export_all).

map(Translations, Schema, Config) ->
    %%io:format("~p~n", [Config]),
    DConfig = add_defaults(Config, Schema),
    %%io:format("~p~n", [DConfig]),
    Conf = transform_datatypes(DConfig, Schema),
    %%io:format("~p~n", [Conf]),
    {DirectMappings, TranslationsToDrop} = lists:foldl(
        fun({Key, Default, Attributes}, {ConfAcc, XlatAcc}) ->
            Mapping = proplists:get_value(mapping, Attributes),
            case {Default =/= undefined, proplists:is_defined(Mapping, Translations)} of
                {true, false} -> 
                    Tokens = string:tokens(Mapping, "."),
                    NewValue = proplists:get_value(Key, Conf),
                    {tyktorp(Tokens, ConfAcc, NewValue), XlatAcc};
                {true, true} -> {ConfAcc, XlatAcc};
                _ -> {ConfAcc, [Mapping|XlatAcc]}
            end
        end, 
        {[], []},
        Schema),
    io:format("~p~n", [TranslationsToDrop]),
    %% Translations
    lists:foldl(
        fun({Mapping, Xlat, _}, Acc) ->
            case lists:member(Mapping, TranslationsToDrop) of
                false ->
                    Tokens = string:tokens(Mapping, "."),
                    NewValue = Xlat(Conf),
                    tyktorp(Tokens, Acc, NewValue);
                _ ->
                    Acc
            end
        end, 
        DirectMappings, 
        Translations). 

%for each token, is it special?
%
%if yes, special processing
%if no, recurse into this with the value from the proplist and tail of tokens
%
%unless the tail of tokens is []
tyktorp([LastToken], Acc, NewValue) ->
    {Type, Token, X} = token_type(LastToken),
    OldValue = proplists:get_value(Token, Acc), 
    New = case Type of
        tuple -> bjorn_util:replace_tuple_element(X, NewValue, OldValue); 
        _ -> NewValue
    end,
    bjorn_util:replace_proplist_value(Token, New, Acc); 
tyktorp([HeadToken|MoreTokens], PList, NewValue) ->
    {_Type, Token, _X} = token_type(HeadToken),
    OldValue = proplists:get_value(Token, PList, []),
    bjorn_util:replace_proplist_value(
        Token,
        tyktorp(MoreTokens, OldValue, NewValue),
        PList).

%% Keeping this around to deal with possible $ prefixed tokens
token_type(Token) ->
    case string:tokens(Token, "$") of
        [Token] -> { normal, list_to_atom(Token), none};
        [X] -> {named, list_to_atom(X), none}
    end.

%% Priority is a nested set of proplists, but each list has only one item
%% for easy merge
%% merge([{K,V}]=Priority, Proplist) ->
%%     case proplists:get_value(K, Proplist) of
%%         undefined -> Proplist ++ Priority;
%%         Existing ->
%%             proplists:delete(K, Proplist) ++ merge(V, Existing) 
%%     end; 
%% merge([], Proplist) -> Proplist;
%% merge(Priority, []) -> Priority.

add_defaults(Conf, Schema) ->

    lists:foldl(
        fun({Key, Default, Attributes}, Acc) ->
            Match = lists:any(
                fun({K, _V}) ->
                    variable_key_match(K, Key)
                end, 
                Conf),
            %% No, then plug in the default
            FuzzyMatch = lists:member($$, Key),
            case {Match, FuzzyMatch} of
                {false, true} -> 
                    Sub = proplists:get_value(include_default, Attributes),
                    [{variable_key_replace(Key, Sub), Default}|Acc];
                {false, false} -> [{Key, Default}|Acc];
                _ -> Acc
            end 
        end, 
        Conf, 
        lists:filter(fun({_K, Def, _A}) -> Def =/= undefined end, Schema)).

transform_datatypes(Conf, Schema) ->
    [ begin
        %% Look up mapping from schema
        {_Key, _Default, Attributes} = find_mapping(Key, Schema),
        %%Mapping = proplists:get_value(mapping, Attributes),
        {DT, _} = proplists:get_value(datatype, Attributes, {undefined, []}),
        {Key, caster(Value, DT)}
    end || {Key, Value} <- Conf].

%% Ok, this is tricky
%% There are three scenarios we have to deal with:
%% 1. The mapping is there! -> return mapping
%% 2. The mapping is not there -> error
%% 3. The mapping is there, but the key in the schema contains a $.
%%      (fuzzy match)
find_mapping(Key, Schema) ->
    {HardMappings, FuzzyMappings} =  lists:foldl(
        fun(Mapping={K, _D, _A}, {HM, FM}) -> 
            case {Key =:= K, variable_key_match(Key, K)} of
                {true, _} -> {[Mapping|HM], FM};
                {_, true} -> {HM, [Mapping|FM]};
                _ -> {HM, FM}
            end
        end,
        {[], []},
        Schema),

    case {length(HardMappings), length(FuzzyMappings)} of
        {1, _} -> hd(HardMappings);
        {0, 1} -> hd(FuzzyMappings);
        {0, 0} -> {error, io_lib:format("~s not_found", [Key])};
        {X, Y} -> {error, io_lib:format("~p hard mappings and ~p fuzzy mappings found for ~s", [X, Y, Key])}
    end.

variable_key_match(Key, KeyDef) ->
    KeyTokens = string:tokens(Key, "."),
    KeyDefTokens = string:tokens(KeyDef, "."),

    case length(KeyTokens) =:= length(KeyDefTokens) of
        true ->
            Zipped = lists:zip(KeyTokens, KeyDefTokens),
            lists:all(
                fun({X,Y}) ->
                    X =:= Y orelse hd(Y) =:= $$
                end,
                Zipped);
        _ -> false
    end.

variable_key_replace(Key, Sub) ->
    KeyTokens = string:tokens(Key, "."), 
    string:join([ begin 
        case hd(Tok) of
            $$ -> Sub;
            _ -> Tok
        end
    end|| Tok <- KeyTokens], "."). 

caster(X, enum) -> list_to_atom(X);
caster(X, integer) -> list_to_integer(X);
caster(X, ip) ->
    Parts = string:tokens(X, ":"),
    [Port|BackwardsIP] = lists:reverse(Parts),
    {string:join(lists:reverse(BackwardsIP), ":"), list_to_integer(Port)};
caster(X, _) -> X.

-spec file(string()) -> [{string(), any(), list()}].
file(Filename) ->
    {ok, B} = file:read_file(Filename),
    %% TODO: Hardcoded utf8
    S = unicode:characters_to_list(B, utf8),
    string(S).

-spec string(string()) -> {[{string(), fun(), list()}], [{string(), any(), list()}]}.
string(S) -> 
    {ok, Tokens, _} = erl_scan:string(S),
    CommentTokens = erl_comment_scan:string(S),
    Schemas = parse_schema(Tokens, CommentTokens),
    lists:partition(fun({_, _, Attributes}) -> proplists:is_defined(translation, Attributes) end, Schemas). 

parse_schema(Tokens, Comments) ->
    parse_schema(Tokens, Comments, []).

parse_schema([], _, Acc) ->
    lists:reverse(Acc);
parse_schema(ScannedTokens, CommentTokens, Acc) ->
    {LineNo, Tokens, TailTokens } = parse_schema_tokens(ScannedTokens),
    {Comments, TailComments} = lists:foldr(
        fun(X={CommentLineNo, _, _, Comment}, {C, TC}) -> 
            case CommentLineNo < LineNo of
                true -> {Comment ++ C, TC};
                _ -> {C, [X|TC]}
            end
        end, 
        {[], []}, 
        CommentTokens),
    { Key, Default } = parse(Tokens),
    Attributes = comment_parser(Comments),
    parse_schema(TailTokens, TailComments, [{Key, Default, Attributes}| Acc]).

parse_schema_tokens(Scanned) -> 
    parse_schema_tokens(Scanned, []).

parse_schema_tokens(Scanned, Acc=[{dot, LineNo}|_]) ->
    {LineNo, lists:reverse(Acc), Scanned};
parse_schema_tokens([H|Scanned], Acc) ->
    parse_schema_tokens(Scanned, [H|Acc]).

-spec parse(list()) -> {string(), any()}.
parse(Scanned) ->
    {ok,Parsed} = erl_parse:parse_exprs(Scanned),
    {value, X, _} = erl_eval:exprs(Parsed,[]),
    X.

comment_parser(Comments) ->
    StrippedComments = 
        lists:filter(fun(X) -> X =/= [] end, 
            [percent_stripper(C) || C <- Comments]),
    %% now, let's go annotation hunting

    AttrList = lists:foldl(
        fun(Line, Acc) ->
                case {Line, Acc} of
                    {[ $@ | T], _} ->
                        Annotation = hd(string:tokens(T, [$\s])),
                        [{list_to_atom(Annotation), [percent_stripper(T -- Annotation)] }|Acc];
                    { _, []} -> [];
                    {String, _} ->
                        [{Annotation, Strings}|T] = Acc,
                        [{Annotation, [String|Strings]}|T]
                end
            end, [], StrippedComments), 
    SortedList = lists:reverse([ {Attr, lists:reverse(Value)} || {Attr, Value} <- AttrList]),
    CorrectedList = attribute_formatter(SortedList),
    CorrectedList.

attribute_formatter([{translation, _}| T]) ->
    [{translation, true}| attribute_formatter(T)];
attribute_formatter([{datatype, DT}| T]) ->
    [{datatype, data_typer(DT)}| attribute_formatter(T)];
attribute_formatter([{mapping, Mapping}| T]) ->
    [{mapping, lists:flatten(Mapping)}| attribute_formatter(T)];
attribute_formatter([{include_default, NameSub}| T]) ->
    [{include_default, lists:flatten(NameSub)}| attribute_formatter(T)];
attribute_formatter([{commented, CommentValue}| T]) ->
    [{commented, lists:flatten(CommentValue)}| attribute_formatter(T)];
attribute_formatter([_Other | T]) ->
    attribute_formatter(T); %% TODO: don't throw other things away [ Other | attribute_formatter(T)]
attribute_formatter([]) -> [].

percent_stripper(Line) ->
    percent_stripper_r(percent_stripper_l(Line)).

percent_stripper_l([$%|T]) -> percent_stripper_l(T);
percent_stripper_l([$\s|T]) -> percent_stripper_l(T);
percent_stripper_l(Line) -> Line.

percent_stripper_r(Line) -> 
    lists:reverse(
        percent_stripper_l(
            lists:reverse(Line))).

data_typer(DT) ->
    DataTypes = lists:flatten(DT),
    DataType = hd(string:tokens(DataTypes, [$\s])),
    Extra = DataTypes -- DataType,
    {list_to_atom(DataType), [ percent_stripper(T) || T <- string:tokens(Extra, [$,])] }.

-ifdef(TEST).
map_test() ->
    {Translations, Schema} = file("../test/riak.schema"),
    Conf = conf_parse:file("../test/riak.conf"),
    NewConfig = map(Translations, Schema, Conf),

    NewRingSize = proplists:get_value(ring_creation_size, proplists:get_value(riak_core, NewConfig)), 
    ?assertEqual(32, NewRingSize),

    NewAAE = proplists:get_value(anti_entropy, proplists:get_value(riak_kv, NewConfig)), 
    ?assertEqual({on,[debug]}, NewAAE),

    NewSASL = proplists:get_value(sasl_error_logger, proplists:get_value(sasl, NewConfig)), 
    ?assertEqual(false, NewSASL),

    NewHTTP = proplists:get_value(http, proplists:get_value(riak_core, NewConfig)), 
    ?assertEqual([{"127.0.0.1", 8098}, {"10.0.0.1", 80}], NewHTTP),

    NewPB = proplists:get_value(pb, proplists:get_value(riak_api, NewConfig)), 
    ?assertEqual([{"127.0.0.1", 8087}], NewPB),

    NewHTTPS = proplists:get_value(https, proplists:get_value(riak_core, NewConfig)), 
    ?assertEqual(undefined, NewHTTPS),

    file:write_file("../generated.config",io_lib:fwrite("~p.\n",[NewConfig])),
    ok.

file_test() ->
    {_, Schema} = file("../test/riak.schema"),
    ?assertEqual(36, length(Schema)),
    ?assertEqual(
        {"ring_size", "64", 
                [
                 {datatype,{integer,[]}},
                 {mapping, "riak_core.ring_creation_size"}]},
        lists:nth(1, Schema) 
        ),
    ?assertEqual(
        {"anti_entropy", "on",
                [
                 {datatype,{enum,["on","off","debug"]}},
                 {mapping,"riak_kv.anti_entropy"}]},
        lists:nth(2, Schema) 
        ),
    ?assertEqual(
        { "log.console.file", "./log/console.log",
                [
                 {mapping, "lager.handlers"}
                ]},
        lists:nth(3, Schema) 
        ),
    ?assertEqual(
        { "log.error.file", "./log/error.log",
                [
                 {mapping, "lager.handlers"}
                ]},
        lists:nth(4, Schema) 
        ),
    ?assertEqual(
        { "log.syslog", "off",
                [
                 {datatype,{enum,["on","off"]}},
                 {mapping, "lager.handlers"}
                ]},
        lists:nth(5, Schema) 
        ),
    ?assertEqual(
        { "sasl", "off",
                [
                 {datatype,{enum,["on","off"]}},
                 {mapping, "sasl.sasl_error_logger"}
                ]},
        lists:nth(6, Schema) 
        ),
    ?assertEqual(
        { "listener.http.$name", "127.0.0.1:8098",
                [
                 {datatype,{ip,[]}},
                 {mapping, "riak_core.http"},
                 {include_default,"internal"}
                ]},
        lists:nth(7, Schema) 
        ),
    ?assertEqual(
        { "listener.protobuf.$name", "127.0.0.1:8087",
                [
                 {datatype,{ip,[]}},
                 {mapping, "riak_api.pb"},
                 {include_default,"internal"}
                ]},
        lists:nth(8, Schema) 
        ),
    ?assertEqual(
        { "protobuf.backlog", undefined,
                [
                 {mapping, "riak_api.pb_backlog"},
                 {datatype,{integer,[]}},
                 {commented, "64"}
                ]},
        lists:nth(9, Schema) 
        ),
    ?assertEqual(
        { "ring.state_dir", "./data/ring",
                [
                 {mapping, "riak_core.ring_state_dir"}
                ]},
        lists:nth(10, Schema) 
        ),
    ?assertEqual(
        { "listener.https.$name", undefined,
                [
                 {datatype,{ip,[]}},
                 {mapping, "riak_core.https"},
                 {include_default,"internal"},
                 {commented,"127.0.0.1:8098"}
                ]},
        lists:nth(11, Schema) 
        ),
    ?assertEqual(
        { "ssl.certfile", undefined,
                [
                 {mapping, "riak_core.ssl.certfile"},
                 {commented,"./etc/cert.pem"}
                ]},
        lists:nth(12, Schema) 
        ),
    ?assertEqual(
        { "ssl.keyfile", undefined,
                [
                 {mapping, "riak_core.ssl.keyfile"},
                 {commented,"./etc/key.pem"}
                ]},
        lists:nth(13, Schema) 
        ),
    ?assertEqual(
        { "handoff.port", "8099",
                [
                 {datatype, {integer, []}},
                 {mapping, "riak_core.handoff_port"}
                ]},
        lists:nth(14, Schema) 
        ),
    ?assertEqual(
        { "handoff.ssl.certfile", undefined,
                [
                 {mapping, "riak_core.handoff_ssl_options.certfile"},
                 {commented,"/tmp/erlserver.pem"}
                ]},
        lists:nth(15, Schema) 
        ),
    ?assertEqual(
        { "handoff.ssl.keyfile", undefined,
                [
                 {mapping, "riak_core.handoff_ssl_options.keyfile"}
                ]},
        lists:nth(16, Schema) 
        ),
    ?assertEqual(
        { "dtrace", "off",
                [
                 {datatype, {enum, ["on", "off"]}},
                 {mapping, "riak_core.dtrace_support"}
                ]},
        lists:nth(17, Schema) 
        ),
    ?assertEqual(
        { "platform_bin_dir", "./bin",
                [
                 {mapping, "riak_core.platform_bin_dir"}
                ]},
        lists:nth(18, Schema) 
        ),
    ?assertEqual(
        { "platform_data_dir", "./data",
                [
                 {mapping, "riak_core.platform_data_dir"}
                ]},
        lists:nth(19, Schema) 
        ),
    ?assertEqual(
        { "platform_etc_dir", "./etc",
                [
                 {mapping, "riak_core.platform_etc_dir"}
                ]},
        lists:nth(20, Schema) 
        ),
    ?assertEqual(
        { "platform_lib_dir", "./lib",
                [
                 {mapping, "riak_core.platform_lib_dir"}
                ]},
        lists:nth(21, Schema) 
        ),
    ?assertEqual(
        { "platform_log_dir", "./log",
                [
                 {mapping, "riak_core.platform_log_dir"}
                ]},
        lists:nth(22, Schema) 
        ),
    ?assertEqual(
        { "search", "off",
                [
                 {datatype, {enum, ["on", "off"]}},
                 {mapping, "riak_search.enabled"}
                ]},
        lists:nth(23, Schema) 
        ),
    ?assertEqual(
        { "bitcask.io_mode", "erlang",
                [
                 {datatype, {enum, ["erlang", "nif"]}},
                 {mapping, "bitcask.io_mode"}
                ]},
        lists:nth(24, Schema) 
        ),
    ?assertEqual(
        { "bitcask.data_root", "./data/bitcask",
                [
                 {mapping, "bitcask.data_root"}
                ]},
        lists:nth(25, Schema) 
        ),
    ?assertEqual(
        { "leveldb.data_root", "./data/leveldb",
                [
                 {mapping, "eleveldb.data_root"}
                ]},
        lists:nth(26, Schema) 
        ),
    ?assertEqual(
        { "merge_index.data_root", "./data/merge_index",
                [
                 {mapping, "merge_index.data_root"}
                ]},
        lists:nth(27, Schema) 
        ),
    ?assertEqual(
        { "merge_index.buffer_rollover_size", "1048576",
                [
                 {datatype, {integer,[]}},
                 {mapping, "merge_index.buffer_rollover_size"}
                ]},
        lists:nth(28, Schema) 
        ),
    ?assertEqual(
        { "merge_index.max_compact_segments", "20",
                [
                 {datatype, {integer,[]}},
                 {mapping, "merge_index.max_compact_segments"}
                ]},
        lists:nth(29, Schema) 
        ),
    ?assertEqual(
        {"log.crash.file", "./log/crash.log",
                [
                 {mapping, "lager.crash_log"}
                ]},
        lists:nth(30, Schema)
        ),
    ?assertEqual(
        {"log.crash.msg_size", "65536", 
                [
                 {datatype, {integer, []}},
                 {mapping, "lager.crash_log_msg_size"}
                ]},
        lists:nth(31, Schema)
        ),
    ?assertEqual(
        {"log.crash.size", "10485760", 
                [
                 {datatype, {integer, []}},
                 {mapping, "lager.crash_log_size"}
                ]},
        lists:nth(32, Schema)
        ),
    ?assertEqual(
        {"log.crash.date", "$D0", 
                [
                 {mapping, "lager.crash_log_date"}
                ]},
        lists:nth(33, Schema)
        ),
    ?assertEqual(
        {"log.crash.count", "5", 
                [
                 {datatype, {integer, []}},
                 {mapping, "lager.crash_log_count"}
                ]},
        lists:nth(34, Schema)
        ),
    ?assertEqual(
        {"log.error.redirect", "on", 
                [
                 {datatype, {enum, ["on", "off"]}},
                 {mapping, "lager.error_logger_redirect"}
                ]},
        lists:nth(35, Schema)
        ),
    ?assertEqual(
        {"log.error.messages_per_second", "100", 
                [
                 {datatype, {integer, []}},
                 {mapping, "lager.error_logger_hwm"}
                ]},
        lists:nth(36, Schema)
        ),
    ok.

percent_stripper_test() ->
    ?assertEqual("hi!", percent_stripper("%%% hi!")),
    ?assertEqual("hi!", percent_stripper("%% hi!")),
    ?assertEqual("hi!", percent_stripper("% hi!")),
    ?assertEqual("hi!", percent_stripper(" hi!")),
    ?assertEqual("hi!", percent_stripper(" % % hi!")),
    ?assertEqual("hi!", percent_stripper("% % % hi!")),
    ?assertEqual("hi!", percent_stripper("% % % hi! % % %")),
    ok.

comment_parser_test() ->
    Comments = [
        " ",
        "%% @doc this is a sample doc",
        "%% it spans multiple lines %%",
        "",
        "%% there can be line breaks",
        "%% @datatype enum on, off",
        "%% @advanced",
        "%% @optional",
        "%% @include_default name_substitution",
        "%% @mapping riak_kv.anti_entropy"
    ],
    ParsedComments = comment_parser(Comments),
    ?assertEqual(
        [
          {datatype,{enum,["on","off"]}},
          {include_default, "name_substitution"},
          {mapping, "riak_kv.anti_entropy"}
        ], ParsedComments
        ),
    ok.

caster_ip_test() ->
    ?assertEqual({"127.0.0.1", 8098}, caster("127.0.0.1:8098", ip)),
    ?assertEqual({"2001:0db8:85a3:0042:1000:8a2e:0370:7334", 8098}, caster("2001:0db8:85a3:0042:1000:8a2e:0370:7334:8098", ip)),
    ok.

find_mapping_test() ->
    Mappings = [
        {"key.with.fixed.name", 0, []},
        {"key.with.$variable.name", 1, []}
    ],
    ?assertEqual(
        {"key.with.fixed.name", 0, []}, 
        find_mapping("key.with.fixed.name", Mappings)),
    ?assertEqual(
        {"key.with.$variable.name", 1, []}, 
        find_mapping("key.with.A.name", Mappings)),
    ?assertEqual(
        {"key.with.$variable.name", 1, []}, 
        find_mapping("key.with.B.name", Mappings)),
    ?assertEqual(
        {"key.with.$variable.name", 1, []}, 
        find_mapping("key.with.C.name", Mappings)),
    ?assertEqual(
        {"key.with.$variable.name", 1, []}, 
        find_mapping("key.with.D.name", Mappings)),
    ?assertEqual(
        {"key.with.$variable.name", 1, []}, 
        find_mapping("key.with.E.name", Mappings)),
    ok.
-endif.