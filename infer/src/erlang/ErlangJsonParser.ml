(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module L = Logging
module YSU = Yojson.Safe.Util
module Ast = ErlangAst
open IOption.Let_syntax

type json = Yojson.Safe.t

type 'a parser = json -> 'a option

let unknown name json =
  L.debug Capture Verbose "ErlangAst.Parse: unknown %s: %s@." name (Yojson.Safe.show json) ;
  None


(* Takes a json of the form `List [j1;...;jn] and returns [f j1;...;f jn]. If skip_errors, then
   elements that fail to parse are filtered out; otherwise, a parsing failure propagates up. *)
let to_list ?(skip_errors = false) ~(f : 'a parser) : 'a list parser =
 fun json ->
  try
    let xs = List.map ~f (YSU.to_list json) in
    if skip_errors then Some (List.filter_opt xs) else Option.all xs
  with YSU.Type_error (error, json) -> unknown error json


let default_or (to_a : 'a parser) : 'a option parser = function
  | `String "default" ->
      Some None
  | a ->
      let* a = to_a a in
      Some (Some a)


let to_line json : Ast.line option =
  match json with
  | `Int line ->
      Some line
  | `List [`List (`String "generated" :: _); `List [`String "location"; `Int line]] ->
      Some line
  | `List [`Int line; _] ->
      (* TODO: Next item is the column we can store as well *)
      Some line
  | _ ->
      unknown "line" json


let rec kill_singleton_list json =
  match json with
  | `List (`String _ :: _) ->
      json (* an expression *)
  | `List [x] ->
      kill_singleton_list x (* singleton list dropped *)
  | x ->
      x


let one_list json =
  match kill_singleton_list json with
  | `List (`String _ :: _) as json ->
      `List [json]
  | `List _ as json ->
      json (* already (nonsingleton) list *)
  | json ->
      `List [json]


let to_intlit json =
  match json with
  | `Int x ->
      Some (Printf.sprintf "%d" x)
  | `Intlit s ->
      Some s
  | _ ->
      unknown "intlit" json


let to_binary_operator json : Ast.binary_operator option =
  match json with
  | `String "!" ->
      Some Send
  | `String "*" ->
      Some Mul
  | `String "+" ->
      Some Add
  | `String "++" ->
      Some ListAdd
  | `String "-" ->
      Some Sub
  | `String "--" ->
      Some ListSub
  | `String "/" ->
      Some FDiv
  | `String "/=" ->
      Some NotEqual
  | `String "<" ->
      Some Less
  | `String "=/=" ->
      Some ExactlyNotEqual
  | `String "=:=" ->
      Some ExactlyEqual
  | `String "=<" ->
      Some AtMost
  | `String "==" ->
      Some Equal
  | `String ">" ->
      Some Greater
  | `String ">=" ->
      Some AtLeast
  | `String "and" ->
      Some And
  | `String "andalso" ->
      Some AndAlso
  | `String "band" ->
      Some BAnd
  | `String "bor" ->
      Some BOr
  | `String "bsl" ->
      Some Bsl
  | `String "bsr" ->
      Some Bsr
  | `String "bxor" ->
      Some BXor
  | `String "div" ->
      Some IDiv
  | `String "or" ->
      Some Or
  | `String "orelse" ->
      Some OrElse
  | `String "rem" ->
      Some Rem
  | `String "xor" ->
      Some Xor
  | _ ->
      unknown "binary_operator" json


let to_unary_operator json : Ast.unary_operator option =
  match json with
  | `String "-" ->
      Some UMinus
  | `String "bnot" ->
      Some UBNot
  | `String "not" ->
      Some UNot
  | _ ->
      unknown "unary_operator" json


let to_exception json : Ast.exception_ option =
  match json with
  | `List [`String "atom"; _anno; `String atom] ->
      Some (Atom atom)
  | `List [`String "var"; _anno; `String variable] ->
      Some (Pattern variable)
  | _ ->
      unknown "exception" json


let to_arity json : int option =
  match json with
  | `Int arity ->
      Some arity
  | `List [`String "integer"; _anno; `Int arity] ->
      Some arity
  | _ ->
      unknown "arity" json


let to_module_reference json : Ast.module_reference option =
  match json with
  | `List [`String "atom"; _anno; `String name] ->
      Some (ModuleName name)
  | `List [`String "var"; _anno; `String variable] ->
      Some (ModuleVariable variable)
  | `String name ->
      Some (ModuleName name)
  | _ ->
      unknown "module_reference" json


let to_function_reference json : Ast.function_reference option =
  match json with
  | `List [`String "atom"; _anno; `String name] ->
      Some (FunctionName name)
  | `List [`String "var"; _anno; `String variable] ->
      Some (FunctionVariable variable)
  | `String name ->
      Some (FunctionName name)
  | _ ->
      unknown "function_reference" json


let rec to_expression json : Ast.expression option =
  let expr line simple_expression : Ast.expression option = Some {line; simple_expression} in
  match json with
  | `List [`String "atom"; anno; `Bool atom] ->
      let* line = to_line anno in
      expr line (Literal (Atom (Printf.sprintf "%b" atom)))
  | `List [`String "atom"; anno; `Null] ->
      let* line = to_line anno in
      expr line (Literal (Atom "null"))
  | `List [`String "atom"; anno; `String atom] ->
      let* line = to_line anno in
      expr line (Literal (Atom atom))
  | `List [`String "bc"; anno; expression; qualifiers] ->
      let* line = to_line anno in
      let* expression = to_expression expression in
      let* qualifiers = to_list ~f:to_qualifier qualifiers in
      expr line (BitstringComprehension {expression; qualifiers})
  | `List [`String "bin"; anno; elements] ->
      let* line = to_line anno in
      let* elements = to_list ~f:to_bin_element elements in
      expr line (BitstringConstructor elements)
  | `List [`String "block"; anno; body] ->
      let* line = to_line anno in
      let* body = to_body body in
      expr line (Block body)
  | `List [`String "call"; anno; `List [`String "remote"; `Int _line2; module_; function_]; args] ->
      let* line = to_line anno in
      let* module_ = to_expression module_ in
      let* function_ = to_expression function_ in
      let* args = to_body args in
      expr line (Call {module_= Some module_; function_; args})
  | `List [`String "call"; anno; function_; args] ->
      let* line = to_line anno in
      let* function_ = to_expression function_ in
      let* args = to_body args in
      expr line (Call {module_= None; function_; args})
  | `List [`String "case"; anno; expression; cases] ->
      let* line = to_line anno in
      let* expression = to_expression expression in
      let* cases = to_list ~f:to_case_clause cases in
      expr line (Case {expression; cases})
  | `List [`String "catch"; anno; expression] ->
      let* line = to_line anno in
      let* expression = to_expression expression in
      expr line (Catch expression)
  | `List [`String "char"; anno; charlit] ->
      let* line = to_line anno in
      let* charlit = to_intlit charlit in
      expr line (Literal (Char charlit))
  | `List [`String "cons"; anno; head; tail] ->
      let* line = to_line anno in
      let* head = to_expression head in
      let* tail = to_expression tail in
      expr line (Cons {head; tail})
  | `List [`String "float"; anno; `Float floatlit] ->
      let* line = to_line anno in
      expr line (Literal (Float floatlit))
  | `List [`String "fun"; anno; `List [`String "clauses"; cases]] ->
      let* line = to_line anno in
      let* cases = to_list ~f:to_case_clause cases in
      expr line (Lambda {name= None; cases})
  | `List [`String "fun"; anno; `List [`String "function"; function_; arity]] ->
      let* line = to_line anno in
      let* function_ = to_function_reference function_ in
      let* arity = to_arity arity in
      expr line (Fun {module_= ModuleMissing; function_; arity})
  | `List [`String "fun"; anno; `List [`String "function"; module_; function_; arity]] ->
      let* line = to_line anno in
      let* module_ = to_module_reference module_ in
      let* function_ = to_function_reference function_ in
      let* arity = to_arity arity in
      expr line (Fun {module_; function_; arity})
  | `List [`String "if"; anno; cases] ->
      let* line = to_line anno in
      let* cases = to_list ~f:to_case_clause cases in
      expr line (If cases)
  | `List [`String "integer"; anno; intlit] ->
      let* line = to_line anno in
      let* intlit = to_intlit intlit in
      expr line (Literal (Int intlit))
  | `List [`String "lc"; anno; expression; qualifiers] ->
      let* line = to_line anno in
      let* expression = to_expression expression in
      let* qualifiers = to_list ~f:to_qualifier qualifiers in
      expr line (ListComprehension {expression; qualifiers})
  | `List [`String "map"; anno; map; updates] ->
      let* line = to_line anno in
      let* map = to_expression map in
      let* updates = to_list ~f:to_association updates in
      expr line (Map {map= Some map; updates})
  | `List [`String "map"; anno; updates] ->
      let* line = to_line anno in
      let* updates = to_list ~f:to_association updates in
      expr line (Map {map= None; updates})
  | `List [`String "match"; anno; pattern; body] ->
      let* line = to_line anno in
      let* pattern = to_expression pattern in
      let* body = to_expression body in
      expr line (Match {pattern; body})
  | `List [`String "named_fun"; anno; `String name; cases] ->
      let* line = to_line anno in
      let* cases = to_list ~f:to_case_clause cases in
      expr line (Lambda {name= Some name; cases})
  | `List [`String "nil"; anno] ->
      let* line = to_line anno in
      expr line Nil
  | `List [`String "op"; _anno; `String "+"; argument] ->
      to_expression argument
  | `List [`String "op"; anno; op; argument] ->
      let* line = to_line anno in
      let* op = to_unary_operator op in
      let* argument = to_expression argument in
      expr line (UnaryOperator (op, argument))
  | `List [`String "op"; anno; op; left; right] ->
      let* line = to_line anno in
      let* op = to_binary_operator op in
      let* left = to_expression left in
      let* right = to_expression right in
      expr line (BinaryOperator (left, op, right))
  | `List [`String "receive"; anno; cases; time; handler] ->
      let* line = to_line anno in
      let* cases = to_list ~f:to_case_clause cases in
      let* time = to_expression time in
      let* handler = to_body handler in
      expr line (Receive {cases; timeout= Some {time; handler}})
  | `List [`String "receive"; anno; cases] ->
      let* line = to_line anno in
      let* cases = to_list ~f:to_case_clause cases in
      expr line (Receive {cases; timeout= None})
  | `List [`String "record"; anno; `String name; updates] ->
      let* line = to_line anno in
      let* updates = to_list ~f:to_record_update updates in
      expr line (RecordUpdate {record= None; name; updates})
  | `List [`String "record"; anno; record; `String name; updates] ->
      let* line = to_line anno in
      let* record = to_expression record in
      let* updates = to_list ~f:to_record_update updates in
      expr line (RecordUpdate {record= Some record; name; updates})
  | `List
      [ `String "record_field"
      ; anno
      ; record
      ; `String name
      ; `List [`String "atom"; _anno; `String field] ] ->
      let* line = to_line anno in
      let* record = to_expression record in
      expr line (RecordAccess {record; name; field})
  | `List
      [ `String "record_index"
      ; anno
      ; `String name
      ; `List [`String "atom"; _anno_field; `String field] ] ->
      let* line = to_line anno in
      expr line (RecordIndex {name; field})
  | `List [`String "string"; anno; `List []] ->
      let* line = to_line anno in
      expr line (Literal (String ""))
  | `List [`String "string"; anno; `String s] ->
      let* line = to_line anno in
      expr line (Literal (String s))
  | `List [`String "try"; anno; body; ok_cases; catch_cases; after] ->
      let* line = to_line anno in
      let* body = to_body body in
      let* ok_cases = to_list ~f:to_case_clause ok_cases in
      let* catch_cases = to_list ~f:to_catch_clause catch_cases in
      let* after = to_body after in
      expr line (TryCatch {body; ok_cases; catch_cases; after})
  | `List [`String "tuple"; anno; tuple] ->
      let* line = to_line anno in
      let* xs = to_list ~f:to_expression tuple in
      expr line (Tuple xs)
  | `List [`String "var"; anno; `String variable] ->
      let* line = to_line anno in
      expr line (Variable variable)
  | _ ->
      unknown "expression" json


and to_body json : Ast.expression list option = to_list ~f:to_expression json

and to_association json : Ast.association option =
  match json with
  | `List [`String "map_field_assoc"; _anno; key; value] ->
      let* key = to_expression key in
      let* value = to_expression value in
      Some {Ast.kind= Arrow; key; value}
  | `List [`String "map_field_exact"; _anno; key; value] ->
      let* key = to_expression key in
      let* value = to_expression value in
      Some {Ast.kind= Exact; key; value}
  | _ ->
      unknown "association" json


and to_record_update json : Ast.record_update option =
  match json with
  | `List
      [ `String "record_field"
      ; _anno_update
      ; `List [`String "var"; _anno_field; `String "_"]
      ; expression ] ->
      let* expression = to_expression expression in
      Some {Ast.field= None; expression}
  | `List
      [ `String "record_field"
      ; _anno_update
      ; `List [`String "atom"; _anno_field; `String field]
      ; expression ] ->
      let* expression = to_expression expression in
      Some {Ast.field= Some field; expression}
  | _ ->
      unknown "record_update" json


and to_bin_element json : Ast.bin_element option =
  match json with
  | `List [`String "bin_element"; _anno; expression; size; (* TODO *) _type_specifier_list] ->
      let* expression = to_expression expression in
      let* size = default_or to_expression size in
      Some {Ast.expression; size; types= None}
  | _ ->
      unknown "bin_element" json


and to_catch_pattern json : Ast.catch_pattern option =
  match json with
  | `List
      [ `String "tuple"
      ; _anno
      ; `List [exception_; pattern; `List [`String "var"; _var_anno; `String variable]] ] ->
      let* exception_ = to_exception exception_ in
      let* pattern = to_expression pattern in
      Some {Ast.exception_; pattern; variable}
  | _ ->
      unknown "catch_pattern" json


and to_guards json : Ast.expression list list option =
  let to_guard xs = to_list ~f:to_expression xs in
  to_list ~f:to_guard json


and to_clause : 'pat. 'pat parser -> 'pat Ast.clause parser =
 fun to_pat json ->
  match json with
  | `List [`String "clause"; anno; patterns; guards; body] ->
      let* line = to_line anno in
      let* patterns = to_list ~f:to_pat patterns in
      let* guards = to_guards guards in
      let body = one_list body in
      let* body = to_body body in
      Some {Ast.line; patterns; guards; body}
  | json ->
      unknown "clause" json


and to_qualifier json : Ast.qualifier option =
  match json with
  | `List [`String "b_generate"; _anno; pattern; expression] ->
      let* pattern = to_expression pattern in
      let* expression = to_expression expression in
      Some (Ast.BitsGenerator {pattern; expression})
  | `List [`String "generate"; _anno; pattern; expression] ->
      let* pattern = to_expression pattern in
      let* expression = to_expression expression in
      Some (Ast.Generator {pattern; expression})
  | filter ->
      let* filter = to_expression filter in
      Some (Ast.Filter filter)


and to_case_clause json : Ast.case_clause option = to_clause to_expression json

and to_catch_clause json : Ast.catch_clause option = to_clause to_catch_pattern json

let to_function json : Ast.function_ option =
  match json with
  | `List [`String function_; `Int arity] ->
      let function_ = Ast.FunctionName function_ in
      Some {module_= ModuleMissing; function_; arity}
  | _ ->
      unknown "function" json


let rec to_record_field json : Ast.record_field option =
  match json with
  | `List [`String "record_field"; _; `List [`String "atom"; _; `String field_name]; expr] ->
      Some {Ast.field_name; initializer_= to_expression expr}
  | `List [`String "record_field"; _; `List [`String "atom"; _; `String field_name]] ->
      Some {Ast.field_name; initializer_= None}
  | `List [`String "typed_record_field"; inner_record_field; _] ->
      to_record_field inner_record_field
  | _ ->
      unknown "record_field" json


let to_line_form json : Ast.form option =
  let form line simple_form : Ast.form option = Some {line; simple_form} in
  match json with
  | `List [`String "attribute"; anno; `String "file"; `List [`String path; _anno_file]] ->
      let* line = to_line anno in
      form line (File {path})
  | `List [`String "attribute"; anno; `String "module"; `String module_name] ->
      let* line = to_line anno in
      form line (Module module_name)
  | `List [`String "attribute"; anno; `String "import"; `List [`String module_name; functions]] ->
      let* line = to_line anno in
      let* functions = to_list ~f:to_function functions in
      form line (Import {module_name; functions})
  | `List [`String "attribute"; anno; `String "export"; function_] ->
      let* line = to_line anno in
      let* func_list = to_list ~f:to_function function_ in
      form line (Export func_list)
  | `List [`String "function"; anno; `String function_; `Int arity; case_clause] ->
      let* line = to_line anno in
      let* clauses = to_list ~f:to_case_clause case_clause in
      let function_ : Ast.function_reference = FunctionName function_ in
      let function_ : Ast.function_ = {module_= ModuleMissing; function_; arity} in
      form line (Function {function_; clauses})
  | `List [`String "attribute"; anno; `String "record"; `List [`String name; fields]] ->
      let* line = to_line anno in
      let* field_list = to_list ~f:to_record_field fields in
      form line (Record {name; fields= field_list})
  | `List [`String "attribute"; _anno; `String _unknown_attribute; _] ->
      (* TODO: handle types (spec, ...) *)
      None
  | `List [`String "eof"; _] ->
      None
  | _ ->
      unknown "form" json


let to_module json : Ast.module_ option = to_list ~skip_errors:true ~f:to_line_form json
