(* This module is in charge of handling the [--interpret] option,
   if it is present. *)

open Grammar
module I = Invariant (* artificial dependency; ensures that [Invariant] runs first *)

(* --------------------------------------------------------------------------- *)

(* A sentence is a pair of an optional non-terminal start symbol and a
   list of terminal symbols. *)

type sentence =
    Nonterminal.t option * Terminal.t list

(* --------------------------------------------------------------------------- *)

(* [stream] turns a finite list of terminals into a stream of terminals. *)

exception EndOfStream

let stream (toks : Terminal.t list) : unit -> Terminal.t * Lexing.position * Lexing.position =
  let toks = ref toks in
  fun () ->

    let tok =
      match !toks with
      | tok :: more ->

	  (* Take a token off the list, and return it. *)

	  toks := more;
	  tok

      | [] ->

	  (* The finite list has been exhausted. Here, two plausible behaviors
	     come to mind.

	     The first behavior consists in raising an exception. In that case,
	     we are creating a finite stream, and it is up to the parser to not
	     read past its end.

	     The second behavior consists in returning a designated token. In
	     that case, we are creating an infinite, eventually constant,
	     stream.

	     The choice between these two behaviors is somewhat arbitrary;
	     furthermore, in the second case, the choice of the designated
	     token is arbitrary as well. Here, we adopt the second behavior if
	     and only if the grammar has an EOF token, and we use EOF as the
	     designated token. Again, this is arbitrary, and could be changed
	     in the future. *)

	  match Terminal.eof with
	  | Some eof ->
	      eof
	  | None ->
	      raise EndOfStream

    in

    (* For now, return dummy positions. *)

    tok, Lexing.dummy_pos, Lexing.dummy_pos

(* --------------------------------------------------------------------------- *)

(* [start sentence] returns the start symbol that we should use to interpret
   the sentence [sentence]. *)

(* If a start symbol was explicitly provided as part of the sentence, we use
   it. Otherwise, we use the grammar's unique start symbol, if there is
   one. *)

let start poss ((nto, _) : sentence) : Nonterminal.t =
  match nto with
  | Some nt ->
      nt
  | None ->
      match ProductionMap.is_singleton Lr1.entry with
      | None ->
          Error.error poss
            "Because the grammar has multiple start symbols, each of the\n\
             sentences provided on the standard input channel must be of the\n\
             form: <start symbol>: <token>*"
      | Some (prod, _) ->
          match Production.classify prod with
          | Some nt ->
              nt
          | None ->
              assert false

(* --------------------------------------------------------------------------- *)

(* [interpret] interprets a sentence. *)

let interpret ((_, toks) as sentence) : unit =

  let nt = start [] sentence in

  (* Run the reference interpreter. This can produce a concrete syntax tree
     ([Some cst]), fail with a parser error ([None]), or fail with a lexer error
     ([EndOfStream]). *)

  (* In either case, we produce just one line of output, so it should be clear
     to the user which outcomes correspond to which sentences (should multiple
     sentences be supplied). *)

  begin try
    match
      MenhirLib.Convert.Simplified.traditional2revised
	(ReferenceInterpreter.interpret Settings.trace nt)
	(stream toks)
    with

    | Some cst ->

	(* Success. *)

	Printf.printf "ACCEPT";
	if Settings.interpret_show_cst then begin
	  print_newline();
	  Cst.show stdout cst
	end

    | None ->

	(* Parser failure. *)

	Printf.printf "REJECT"

  with EndOfStream ->

    (* Lexer failure. *)
    
    Printf.printf "OVERSHOOT"

  end;
  print_newline()

(* --------------------------------------------------------------------------- *)

(* [interpret_error] interprets a sentence, expecting it to end in an error. *)

let succeed s =
  Printf.printf
    "OK %d\n# This sentence ends with a syntax error in state %d.\n%!"
    s s;
  exit 0

let fail msg =
  Printf.printf "BAD\n# %s.\n%!" msg;
  exit 1

let interpret_error ((_, toks) as sentence) =
  let nt = start [] sentence in
  let open ReferenceInterpreter in
  match check_error_path nt toks with
  | OInputReadPastEnd ->
      fail "No syntax error occurred"
  | OInputNotFullyConsumed ->
      fail "A syntax error occurred before the last token was reached"
  | OUnexpectedAccept ->
      fail "No syntax error occurred; in fact, the input was accepted"
  | OK state ->
      succeed (Lr1.number state)

(* [convert_located_sentence] is analogous to [interpret_error]. It converts
   a (located) sentence to a state, which it returns. *)

let convert_located_sentence (poss, ((_, toks) as sentence)) =
  let nt = start poss sentence in
  let open ReferenceInterpreter in
  match check_error_path nt toks with
  | OInputReadPastEnd ->
      Error.signal poss "No syntax error occurred";
      -1 (* dummy *)
  | OInputNotFullyConsumed ->
      Error.signal poss "A syntax error occurred before the last token was reached";
      -1 (* dummy *)
  | OUnexpectedAccept ->
      Error.signal poss "No syntax error occurred; in fact, the input was accepted";
      -1 (* dummy *)
  | OK state ->
      Lr1.number state

let convert_entry (sentences, message) =
  List.map convert_located_sentence sentences, message

(* --------------------------------------------------------------------------- *)

(* [setup()] returns a function [read] which reads one sentence from the
   standard input channel. *)

let setup () : unit -> sentence option =

  let open Lexing in
  let lexbuf = from_channel stdin in
  lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = "(stdin)" };

  let read () =
    try
      SentenceParser.optional_sentence SentenceLexer.lex lexbuf
    with Parsing.Parse_error ->
      Error.error (Positions.lexbuf lexbuf) "Ill-formed input sentence."
  in

  read

(* --------------------------------------------------------------------------- *)

(* If [--interpret] is set, interpret the sentences found on the standard
   input channel, then stop, without generating a parser. *)

(* We read a series of sentences from the standard input channel. To allow
   interactive use, we interpret each sentence as soon as it is read. *)

let () =
  if Settings.interpret then
    let read = setup() in
    while true do
      match read() with
      | None ->
  	  exit 0
      | Some sentence ->
	  interpret sentence
    done

(* --------------------------------------------------------------------------- *)

(* If [--interpret-error] is set, interpret one sentence found on the standard
   input channel, then stop, without generating a parser. *)

(* We read just one sentence, confirm that this sentence ends in an error, and
   (if that is the case) display the number of the state that is reached. *)

let () =
  if Settings.interpret_error then
    let read = setup() in
    match read() with
    | None ->
      exit 1 (* abnormal: no input *)
    | Some sentence ->
        interpret_error sentence (* never returns *)

(* --------------------------------------------------------------------------- *)

(* If [--compile-errors <filename>] is set, compile the error message
   descriptions found in file [filename] down to OCaml code, then stop. *)

(* TEMPORARY old
let read filename =
  let lexbuf = Lexing.from_string (IO.read_whole_file filename) in
  lexbuf.Lexing.lex_curr_p <-
    { 
      Lexing.pos_fname = filename; 
      Lexing.pos_lnum  = 1;
      Lexing.pos_bol   = 0; 
      Lexing.pos_cnum  = 0
    };
  try
    SentenceParser.file SentenceLexer.lex lexbuf
  with Parsing.Parse_error ->
    Error.error (Positions.lexbuf lexbuf) "Ill-formed error message description file."
      (* TEMPORARY could improve this message... *)

let () =
  Settings.compile_errors |> Option.iter (fun filename ->
    (* Read the file. *)
    let entries = read filename in
    (* Convert every sentence to a state number. This can signal errors.
       We report all of them. *)
    let _entries = List.map convert_entry entries in
    if Error.errors() then exit 1;
    exit 0
  )
*)
let () =
  Settings.compile_errors |> Option.iter (fun filename ->
    (* Read the file. (Don't bother closing it.) *)
    let c = open_in filename in
    let lexbuf = Lexing.from_channel c in
    lexbuf.Lexing.lex_curr_p <-
    { 
      Lexing.pos_fname = filename; 
      Lexing.pos_lnum  = 1;
      Lexing.pos_bol   = 0; 
      Lexing.pos_cnum  = 0
    };
    let rec loop accu =
      (* Try to read a non-empty series of non-empty sentences. *)
      SentenceLexer.skip lexbuf;
      match SentenceParser.entry1 SentenceLexer.lex lexbuf with
      | [] ->
          (* We have read [EOF]. Stop. *)
          List.rev accu
      | sentences ->
          (* We have read at least one sentence. Now, read a block of text. *)
          SentenceLexer.skip lexbuf;
          let text = SentenceLexer.block (Buffer.create 512) lexbuf in
          (* Continue. *)
          loop ((sentences, text) :: accu)
    in
    let entries = loop [] in
    (* Convert every sentence to a state number. This can signal errors.
       We report all of them. *)
    let _entries = List.map convert_entry entries in
    if Error.errors() then exit 1;
    exit 0
  )

