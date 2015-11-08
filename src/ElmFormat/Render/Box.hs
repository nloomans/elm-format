{-# OPTIONS_GHC -Wall #-}
module ElmFormat.Render.Box where

import Elm.Utils ((|>))
import Box

import AST.V0_15
import qualified AST.Declaration
import qualified AST.Expression
import qualified AST.Literal as L
import qualified AST.Module
import qualified AST.Module.Name as MN
import qualified AST.Pattern
import qualified AST.Type
import qualified AST.Variable
import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import qualified Reporting.Annotation as RA
import Text.Printf (printf)


splitWhere :: (a -> Bool) -> [a] -> [[a]]
splitWhere predicate list =
    let
        merge acc result =
            (reverse acc):result

        step (acc,result) next =
            if predicate next then
                ([], merge (next:acc) result)
            else
                (next:acc, result)
    in
      list
          |> foldl step ([],[])
          |> uncurry merge
          |> dropWhile null
          |> reverse


formatModule :: AST.Module.Module -> Box'
formatModule modu =
    vbox
        [ hbox
            [ text "module "
            , depr $ line $ formatName $ AST.Module.name modu
            , case formatListing $ fmap RA.drop $ AST.Module.exports modu of
                Just listing ->
                    case isLine listing of
                        Just listing' ->
                            depr $ line $ row [ space, listing' ]
                        _ ->
                            text "<TODO: multiline module listing>"
                _ ->
                    empty
            , text " where"
            ]
            |> margin 1
        , formatModuleDocs (AST.Module.docs modu)
            |> fmap depr
            |> fmap (margin 1)
            |> Maybe.fromMaybe empty
        , case AST.Module.imports modu of
            [] ->
                empty
            imports ->
                imports
                |> List.sortOn (fst . RA.drop)
                |> map (depr . formatImport)
                |> vbox
                |> margin 2
        , vbox (map formatDeclaration $ AST.Module.body modu)
        ]


formatModuleDocs :: RA.Located (Maybe String) -> Maybe Box
formatModuleDocs adocs =
    case RA.drop adocs of
        Nothing ->
            Nothing
        Just docs ->
            Just $ formatDocComment docs


formatDocComment :: String -> Box
formatDocComment docs =
    case lines docs of
        [] ->
            line $ row [ punc "{-|", space, punc "-}" ]
        (first:[]) ->
            stack
                [ line $ row [ punc "{-|", space, literal first ]
                , line $ punc "-}"
                ]
        (first:rest) ->
            stack
                [ line $ row [ punc "{-|", space, literal first ]
                , stack $ map (line . literal) rest
                , line $ punc "-}"
                ]


formatName :: MN.Raw -> Line
formatName name =
    identifier (List.intercalate "." name)


formatImport :: AST.Module.UserImport -> Box
formatImport aimport =
    case RA.drop aimport of
        (name,method) ->
            let
                as =
                    case AST.Module.alias method of
                        Nothing ->
                            formatName name
                        Just alias ->
                            row
                                [ formatName name
                                , space
                                , keyword "as"
                                , space
                                , identifier alias
                                ]
            in
                case formatListing $ AST.Module.exposedVars method of
                    Just listing ->
                        case isLine listing of
                            Just listing' ->
                                line $ row
                                    [ keyword "import"
                                    , space
                                    , as
                                    , space
                                    , keyword "exposing"
                                    , space
                                    , listing'
                                    ]
                            _ ->
                                line $ keyword "<TODO: multiline exposing>"
                    Nothing ->
                        line $ row
                            [ keyword "import"
                            , space
                            , as
                            ]


formatListing :: AST.Variable.Listing AST.Variable.Value-> Maybe Box
formatListing listing =
    case listing of
        AST.Variable.Listing [] False ->
            Nothing
        AST.Variable.Listing _ True -> -- Not possible for first arg to be non-empty
            Just $ line $ keyword "(..)"
        AST.Variable.Listing vars False ->
            Just $ elmGroup False "(" "," ")" False $ map formatVarValue vars


formatStringListing :: AST.Variable.Listing String -> Maybe Line
formatStringListing listing =
    case listing of
        AST.Variable.Listing [] False ->
            Nothing
        AST.Variable.Listing _ True -> -- Not possible for first arg to be non-empty
            Just $ keyword "(..)"
        AST.Variable.Listing vars False ->
            Just $ row
                [ punc "("
                , row $ List.intersperse (row [punc ",", space]) $ map identifier vars
                , punc ")"
                ]


formatVarValue :: AST.Variable.Value -> Box
formatVarValue aval =
    case aval of
        AST.Variable.Value val ->
            formatCommented (line . formatVar) val -- TODO: comments not tested
        AST.Variable.Alias name ->
            line $ identifier name
        AST.Variable.Union name listing ->
            case formatStringListing listing of
                Just listing' ->
                    line $ row
                        [ identifier name
                        , listing'
                        ]
                Nothing ->
                    line $ identifier name


isDefinition :: AST.Expression.Def' -> Bool
isDefinition def =
    case def of
        AST.Expression.Definition _ _ _ _ ->
            True
        _ ->
            False


formatDeclaration :: AST.Declaration.Decl -> Box'
formatDeclaration decl =
    case decl of
        AST.Declaration.Comment docs ->
            depr $ formatDocComment docs
        AST.Declaration.Decl adecl ->
            case RA.drop adecl of
                AST.Declaration.Definition def ->
                    formatDefinition False def
                        |> depr
                        |> if isDefinition (RA.drop def) then margin 2 else id

                AST.Declaration.Datatype name args ctors ->
                    vbox
                        [ hbox
                            [ text "type "
                            , text name
                            , hboxlist " " " " "" text args
                            ]
                        , vboxlist
                            (text "= ") "| "
                            empty
                            (\(c, args') -> hbox2 (text c) (hboxlist " " " " "" (depr . formatType' ForCtor) args')) ctors
                            |> indent' 4
                        ]
                        |> margin 2
                AST.Declaration.TypeAlias name args typ ->
                    vbox
                        [ hboxlist "type alias " " " " =" text (name:args)
                        , (depr . formatType) typ
                            |> indent' 4
                        ]
                        |> margin 2
                AST.Declaration.PortAnnotation name typ ->
                    hbox
                        [ text "port "
                        , text name
                        , text " : "
                        , (depr . formatType) typ
                        ]
                AST.Declaration.PortDefinition name expr ->
                    vbox
                        [ hbox
                            [ text "port "
                            , text name
                            , text " ="
                            ]
                        , formatExpression False Nothing expr
                            |> indent
                            |> depr
                        ]
                        |> margin 2
                AST.Declaration.Fixity assoc precedence name ->
                    hbox
                        [ case assoc of
                              AST.Declaration.L -> text "infixl"
                              AST.Declaration.R -> text "infixr"
                              AST.Declaration.N -> text "infix"
                        , text " "
                        , text $ show precedence
                        , text " "
                        , depr $ formatCommented (line . formatInfixVar) name
                        ]


formatDefinition :: Bool -> AST.Expression.Def -> Box
formatDefinition compact adef =
    case RA.drop adef of
        AST.Expression.Definition name args expr multiline ->
            case
                ( compact
                , multiline
                , isLine $ formatPattern True name
                , allSingles $ map (formatPattern True) args
                , isLine $ formatExpression False Nothing expr
                )
            of
                (True, False, Just name', Just args', Just expr') ->
                    line $ row
                        [ row $ List.intersperse space $ (name':args')
                        , space
                        , punc "="
                        , space
                        , expr'
                        ]
                (_, _, Just name', Just args', _) ->
                    stack
                        [ line $ row
                            [ row $ List.intersperse space $ (name':args')
                            , space
                            , punc "="
                            ]
                        , formatExpression False Nothing expr
                            |> indent
                        ]
                _ ->
                    line $ keyword "<TODO: let binding with multiline name/pattern>"
        AST.Expression.TypeAnnotation name typ ->
            case
                ( isLine $ formatCommented (line . formatVar) name -- TODO: comments not tested
                , isLine $ formatType typ
                )
            of
                (Just name', Just typ') ->
                    line $ row
                        [ name'
                        , space
                        , punc ":"
                        , space
                        , typ'
                        ]
                _ ->
                    line $ keyword "<TODO: multiline type annotation>"


formatPattern :: Bool -> AST.Pattern.Pattern -> Box
formatPattern parensRequired apattern =
    case RA.drop apattern of
        AST.Pattern.Data ctor patterns ->
            elmApplication
                (line $ formatVar ctor)
                (map (formatPattern True) patterns)
        AST.Pattern.Tuple patterns ->
            elmGroup True "(" "," ")" False $ map (formatPattern False) patterns
        AST.Pattern.Record fields ->
            elmGroup True "{" "," "}" False $ map (line . identifier) fields
        AST.Pattern.Alias name pattern ->
            case isLine $ formatPattern True pattern of
                Just pattern' ->
                    line $ row
                        [ pattern'
                        , space
                        , keyword "as"
                        , space
                        , identifier name
                        ]
                _ -> -- TODO
                    line $ keyword "<TODO-multiline PAttern alias>"
            |> (if parensRequired then addParens else id)
        AST.Pattern.Var var ->
            formatCommented (line . formatVar) var -- TODO: comments not tested
        AST.Pattern.Anything ->
            line $ keyword "_"
        AST.Pattern.Literal lit ->
            formatLiteral lit


addSuffix :: Maybe Line -> Box -> Box
addSuffix suffix b =
    case suffix of
        Nothing ->
            b
        Just suffix' ->
            case destructure b of
                (l,[]) ->
                    line $ row [ l, suffix' ]
                (l1,ls) ->
                    stack $
                        [ line l1 ]
                        ++ (map line $ init ls)
                        ++ [ line $ row [ last ls, suffix' ] ]


formatRecordPair :: (String, AST.Expression.Expr, Bool) -> Box
formatRecordPair (k,v,multiline') =
    case
        ( multiline'
        , isLine $ formatExpression False Nothing v
        )
    of
        (False, Just v') ->
            line $ row
                [ identifier k
                , space
                , punc "="
                , space
                , v'
                ]
        _ ->
            stack
                [ line $ row [ identifier k, space, punc "=" ]
                , formatExpression False Nothing v
                    |> indent
                ]


formatExpression :: Bool -> Maybe Line -> AST.Expression.Expr -> Box
formatExpression inList suffix aexpr =
    case RA.drop aexpr of
        AST.Expression.Literal lit ->
            formatCommented (formatLiteral) lit

        AST.Expression.Var v ->
            formatCommented (line . formatVar) v -- TODO: comments not tested
                |> addSuffix suffix

        AST.Expression.Range left right multiline ->
            case
                ( multiline
                , isLine $ formatExpression False Nothing left
                , isLine $ formatExpression False Nothing right
                )
            of
                (False, Just left', Just right') ->
                    line $ row
                        [ punc "["
                        , left'
                        , punc ".."
                        , right'
                        , punc "]"
                        ]
                _ ->
                    stack
                        [ line $ punc "["
                        , formatExpression False Nothing left
                            |> indent
                        , line $ punc ".."
                        , formatExpression False Nothing right
                            |> indent
                        , line $ punc "]"
                        ]

        AST.Expression.ExplicitList exprs multiline ->
            elmGroup True "[" "," "]" multiline $ map (formatExpression multiline Nothing) exprs

        AST.Expression.Binops left ops multiline ->
            let
                left' =
                    formatExpression False Nothing left

                ops' =
                    ops |> map fst |> map (formatCommented (line. formatInfixVar)) -- TODO: comments not

                es =
                    ops |> map snd |> map (formatExpression inList Nothing)
            in
                case
                    ( multiline
                    , isLine $ left'
                    , allSingles $ ops'
                    , allSingles $ es
                    )
                of
                    (False, Just left'', Just ops'', Just es') ->
                        zip ops'' es'
                            |> map (\(op,e) -> row [op, space, e])
                            |> List.intersperse space
                            |> (:) space
                            |> (:) left''
                            |> row
                            |> line
                    (_, _, Just ops'', _) ->
                        zip ops'' es
                            |> map (\(op,e) -> prefix (row [op, space]) e)
                            |> stack
                            |> (\body -> stack [left', indent body])
                    _ ->
                        line $ keyword "<TODO: multiline binary operator>"

        AST.Expression.Lambda patterns expr multiline ->
            case
                ( multiline
                , allSingles $ map (formatPattern True) patterns
                , isLine $ formatExpression False Nothing expr
                )
            of
                (False, Just patterns', Just expr') ->
                    line $ row
                        [ punc "\\"
                        , row $ List.intersperse space $ patterns'
                        , space
                        , punc "->"
                        , space
                        , expr'
                        ]
                (_, Just patterns', _) ->
                    stack
                        [ line $ row
                            [ punc "\\"
                            , row $ List.intersperse space $ patterns'
                            , space
                            , punc "->"
                            ]
                        , formatExpression False Nothing expr
                            |> indent
                        ]
                _ ->
                    line $ keyword "<TODO: multiline pattern in lambda>"

        AST.Expression.Unary AST.Expression.Negative e ->
            prefix (punc "-") $ formatExpression False Nothing e

        AST.Expression.App left args multiline ->
            case
                ( multiline
                , isLine $ formatExpression False Nothing left
                , allSingles $ map (formatExpression False Nothing) args
                )
            of
                (False, Just left', Just args') ->
                  line $ row
                      $ List.intersperse space $ (left':args')
                _ ->
                    stack
                        [ formatExpression False Nothing left
                        , args
                            |> map (formatExpression False Nothing)
                            |> stack
                            |> indent
                        ]

        AST.Expression.If [] els ->
            stack
                [ line $ keyword "<INVALID IF EXPRESSION>"
                , formatExpression False Nothing els
                    |> indent
                ]
        AST.Expression.If (if':elseifs) els ->
            let
                opening key multiline cond =
                    case (multiline, isLine cond) of
                        (False, Just cond') ->
                            line $ row
                                [ keyword key
                                , space
                                , cond'
                                , space
                                , keyword "then"
                                ]
                        _ ->
                            stack
                                [ line $ keyword key
                                , cond |> indent
                                , line $ keyword "then"
                                ]

                clause key (cond,multiline,body) =
                    stack
                        [ opening key multiline $ formatExpression False Nothing cond
                        , formatExpression False Nothing body
                            |> indent
                        ]
            in
                stack $
                    [ clause "if" if']
                    ++ ( elseifs |> map (clause "else if") )
                    ++
                    [ line $ keyword "else"
                    , formatExpression False Nothing els
                        |> indent
                    ]

        AST.Expression.Let defs expr ->
            stack
                [ line $ keyword "let"
                , defs
                    |> map (\x -> (isDefinition $ RA.drop x, formatDefinition True x))
                    |> splitWhere fst
                    |> List.intersperse [(False, blankLine)]
                    |> concat
                    |> map snd
                    |> stack
                    |> indent
                , line $ keyword "in"
                , formatExpression False Nothing expr
                    |> indent
                ]

        AST.Expression.Case (subject,multiline) clauses ->
            let
                opening =
                  case
                      ( multiline
                      , isLine $ formatExpression False Nothing subject
                      )
                  of
                      (False, Just subject') ->
                          line $ row
                              [ keyword "case"
                              , space
                              , subject'
                              , space
                              , keyword "of"
                              ]
                      _ ->
                          stack
                              [ line $ keyword "case"
                              , formatExpression False Nothing subject
                                  |> indent
                              , line $ keyword "of"
                              ]

                clause (pat,expr) =
                    case isLine $ formatPattern True pat of
                        Just pat' ->
                            stack
                                [ line $ row [ pat', space, keyword "->"]
                                , formatExpression False Nothing expr
                                    |> indent
                                ]
                        _ ->
                            line $ keyword "<TODO: multiline case pattern>"
            in
                stack
                    [ opening
                    , clauses
                        |> map clause
                        |> List.intersperse blankLine
                        |> stack
                        |> indent
                    ]

        AST.Expression.Tuple exprs multiline ->
            elmGroup True "(" "," ")" multiline $ map (formatExpression False Nothing) exprs

        AST.Expression.TupleFunction n ->
            line $ keyword $ "(" ++ (List.replicate (n+1) ',') ++ ")"

        AST.Expression.Access expr field ->
            formatExpression False Nothing expr -- TODO: needs to have parens in some cases
                |> addSuffix (Just $ row $ [punc ".", identifier field])

        AST.Expression.AccessFunction field ->
            line $ identifier $ "." ++ field

        AST.Expression.RecordUpdate base pairs multiline ->
            case
                ( multiline
                , isLine $ formatExpression False Nothing base
                , allSingles $ map formatRecordPair pairs
                )
            of
                (False, Just base', Just pairs') ->
                    line $ row
                        [ punc "{"
                        , space
                        , base'
                        , space
                        , punc "|"
                        , space
                        , row $ List.intersperse commaSpace pairs'
                        , space
                        , punc "}"
                        ]
                _ ->
                    case map formatRecordPair pairs of
                        [] ->
                            line $ keyword "<INVALID RECORD EXTENSION>"
                        (first:rest) ->
                            stack
                                [ formatExpression False Nothing base
                                    |> prefix (row [punc "{", space])
                                , stack
                                    [ prefix (row [punc "|", space]) first
                                    , stack $ map (prefix (row [punc ",", space])) rest
                                    ]
                                    |> indent
                                , line $ punc "}"
                                ]
            |> addSuffix suffix

        AST.Expression.Record pairs multiline ->
            case
                ( multiline
                , allSingles $ map formatRecordPair pairs
                )
            of
                (False, Just pairs') ->
                    line $ row
                        [ punc "{"
                        , space
                        , row $ List.intersperse commaSpace pairs'
                        , space
                        , punc "}"
                        ]
                _ ->
                    elmGroup True "{" "," "}" multiline $ map formatRecordPair pairs
            |> addSuffix suffix

        AST.Expression.Parens expr multiline ->
            case (multiline, isLine $ formatExpression False Nothing expr) of
                (False, Just expr') ->
                    line $ row [ punc "(", expr', punc ")" ]
                _ ->
                    stack
                        [ formatExpression False Nothing expr
                            |> prefix (punc "(")
                        , line $ punc ")"
                        ]
            |> addSuffix suffix

        AST.Expression.GLShader _ _ _ ->
            line $ keyword "<TODO: glshader>"


formatCommented :: (a -> Box) -> Commented a -> Box
formatCommented format commented =
    case commented of
        Commented comments inner ->
            case
                ( allSingles $ map formatComment comments
                , isLine $ format inner
                )
            of
                (Just [], Just inner') ->
                    line inner'
                (Just cs, Just inner') ->
                    line $ row
                        [ row cs
                        , space
                        , inner'
                        ]
                _ ->
                    stack
                        [ stack $ map formatComment comments
                        , format inner
                        ]


formatComment :: Comment -> Box
formatComment comment =
    case comment of
        BlockComment c ->
            case lines c of
                (l:[]) ->
                    line $ row
                        [ punc "{-"
                        , space
                        , literal l
                        , space
                        , punc "-}"
                        ]
                (l1:ls) -> -- TODO: not tested
                    stack
                        [ line $ row
                            [ punc "{-"
                            , space
                            , literal l1
                            ]
                        , stack $ map (line . literal) ls
                        , line $ punc "-}"
                        ]


formatLiteral :: L.Literal -> Box
formatLiteral lit =
    case lit of
        L.IntNum i ->
            line $ literal $ show i
        L.FloatNum f ->
            line $ literal $ show f
        L.Chr c ->
            formatString SChar [c]
        L.Str s multi ->
            formatString (if multi then SMulti else SString) s
        L.Boolean True ->
            line $ literal "True"
        L.Boolean False ->
            line $ literal "False" -- TODO: not tested


data StringStyle
    = SChar
    | SString
    | SMulti
    deriving (Eq)


formatString :: StringStyle -> String -> Box
formatString style s =
    let
        hex c =
            if Char.ord c <= 0xFF then
                "\\x" ++ (printf "%02X" $ Char.ord c)
            else
                "\\x" ++ (printf "%04X" $ Char.ord c)

        fix c =
            if (style == SMulti) && c == '\n' then
                [c]
            else if c == '\n' then
                "\\n"
            else if c == '\t' then
                "\\t"
            else if c == '\\' then
                "\\\\"
            else if (style == SString) && c == '\"' then
                "\\\""
            else if (style == SChar) && c == '\'' then
                "\\\'"
            else if not $ Char.isPrint c then
                hex c
            else if c == ' ' then
                [c]
            else if Char.isSpace c then
                hex c
            else
                [c]
    in
        case style of
            SChar ->
                line $ row
                    [ punc "\'"
                    , literal $ concatMap fix s
                    , punc "\'"
                    ]
            SString ->
                line $ row
                    [ punc "\""
                    , literal $ concatMap fix s
                    , punc "\""
                    ]
            SMulti ->
                line $ literal $ "\"\"\"" ++ concatMap fix s ++ "\"\"\""


data TypeParensRequired
    = ForLambda
    | ForCtor
    | NotRequired
    deriving (Eq)


formatType :: AST.Type.Type -> Box
formatType =
    formatType' NotRequired


wrap :: Line -> Line -> [Line] -> Line -> Box
wrap left first rest right =
    stack
        [ line $ row [left, first]
        , stack (map (\l -> line $ row [space, space, l]) rest)
        , line $ right
        ]


addParens :: Box -> Box
addParens b =
    case destructure b of
        (l, []) ->
            line $ row
                [ punc "("
                , l
                , punc ")"
                ]
        (first, rest) ->
            wrap (punc "(") first rest (punc ")")


commaSpace :: Line
commaSpace =
    row
        [ punc ","
        , space
        ]


formatType' :: TypeParensRequired -> AST.Type.Type -> Box
formatType' requireParens atype =
    case RA.drop atype of
        AST.Type.RLambda first rest ->
            case
                allSingles $ map (formatType' ForLambda) (first:rest)
            of
                Just typs ->
                    line $ row $ List.intersperse (row [ space, keyword "->", space]) typs
                _ -> -- TODO: not tested
                    stack
                        [ formatType' ForLambda first
                        , rest
                            |> map (formatType' ForLambda)
                            |> map (prefix (keyword "->"))
                            |> stack
                        ]
            |> (if requireParens /= NotRequired then addParens else id)
        AST.Type.RVar var ->
            line $ identifier var
        AST.Type.RType var ->
            line $ formatVar var
        AST.Type.RApp ctor args ->
            elmApplication
                (formatType' ForCtor ctor)
                (map (formatType' ForCtor) args)
                |> (if requireParens == ForCtor then addParens else id)
        AST.Type.RTuple (first:rest) ->
            elmGroup True "(" "," ")" False (map formatType (first:rest))
        AST.Type.RTuple [] ->
            line $ keyword "()"
        AST.Type.RRecord ext fields multiline ->
            let
                formatField (name, typ, multiline') =
                    case (multiline', destructure (formatType typ)) of
                        (False, (first, [])) ->
                            line $ row
                                [ identifier name
                                , space
                                , punc ":"
                                , space
                                , first
                                ]
                        _ ->
                            stack
                                [ line $ row
                                    [ identifier name
                                    , space
                                    , punc ":"
                                    ]
                                , formatType typ
                                    |> indent
                                ]
            in
                case (ext, fields) of
                    (Just _, []) ->
                        line $ keyword "<INVALID RECORD EXTENSION>"
                    (Just typ, first:rest) ->
                        case
                            ( multiline
                            , isLine $ formatType typ
                            , allSingles $ map formatField fields
                            )
                        of
                            (False, Just typ', Just fields') ->
                                line $ row
                                    [ punc "{"
                                    , space
                                    , typ'
                                    , space
                                    , punc "|"
                                    , space
                                    , row (List.intersperse commaSpace fields')
                                    , space
                                    , punc "}"
                                    ]
                            _ ->
                                stack
                                    [ prefix (row [punc "{", space]) (formatType typ)
                                    , stack
                                        ([ prefix (row [punc "|", space]) $ formatField first ]
                                        ++ (map (prefix (row [punc ",", space]) . formatField) rest))
                                        |> indent
                                    , line $ punc "}"
                                    ]
                    (Nothing, _) ->
                        elmGroup True "{" "," "}" multiline (map formatField fields)


formatVar :: AST.Variable.Ref -> Line
formatVar var =
    case var of
        AST.Variable.VarRef name ->
            identifier name
        AST.Variable.OpRef name ->
            identifier $ "(" ++ name ++ ")"
        AST.Variable.WildcardRef ->
            keyword "_" -- TODO: not tested


formatInfixVar :: AST.Variable.Ref -> Line
formatInfixVar var =
    case var of
        AST.Variable.VarRef name ->
            identifier $ "`" ++ name ++ "`" -- TODO: not tested
        AST.Variable.OpRef name ->
            identifier name
        AST.Variable.WildcardRef ->
            keyword "_" -- TODO: should never happen
