(* *********************************************************************)
(*                                                                     *)
(*                              Menhir                                 *)
(*                                                                     *)
(*          Jacques-Henri Jourdan, INRIA Paris-Rocquencourt            *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the GNU Lesser General Public License as        *)
(*  published by the Free Software Foundation, either version 3 of     *)
(*  the License, or  (at your option) any later version.               *)
(*                                                                     *)
(* *********************************************************************)

From Coq Require Import Streams List Syntax.
From Coq.ssr Require Import ssreflect.
Require Automaton.
Require Import Alphabet Grammar Validator_safe.

Module Make(Import A:Automaton.T).
Module Import ValidSafe := Validator_safe.Make A.

(** A few helpers for dependent types. *)

(** Decidable propositions. *)
Class Decidable (P : Prop) := decide : {P} + {~P}.
Arguments decide _ {_}.

(** A [Comparable] type has decidable equality. *)
Instance comparable_decidable_eq T `{ComparableUsualEq T} (x y : T) :
  Decidable (x = y).
Proof.
  unfold Decidable.
  destruct (compare x y) eqn:EQ; [left; apply compare_eq; intuition | ..];
    right; intros ->; by rewrite compare_refl in EQ.
Defined.

Instance list_decidable_eq T :
  (forall x y : T, Decidable (x = y)) ->
  (forall l1 l2 : list T, Decidable (l1 = l2)).
Proof. unfold Decidable. decide equality. Defined.

Ltac subst_existT :=
  repeat
    match goal with
    | _ => progress subst
    | H : @existT ?A ?P ?x ?y1 = @existT ?A ?P ?x ?y2 |- _ =>
      let DEC := fresh in
      assert (DEC : forall u1 u2 : A, Decidable (u1 = u2)) by apply _;
      apply Eqdep_dec.inj_pair2_eq_dec in H; [|by apply DEC];
      clear DEC
    end.

(** The interpreter is written using dependent types. In order to
  avoid reducing proof terms while executing the parser, we thunk all
  the propositions behind an arrow.
  Note that thunkP is still in Prop so that it is erased by
  extraction.
 *)
Definition thunkP (P : Prop) : Prop := True -> P.

(** Sometimes, we actually need a reduced proof in a program (for
  example when using an equality to cast a value). In that case,
  instead of reducing the proof we already have, we reprove the
  assertion by using decidability. *)
Definition reprove {P} `{Decidable P} (p : thunkP P) : P :=
  match decide P with
  | left p => p
  | right np => False_ind _ (np (p I))
  end.

(** Combination of reprove with eq_rect. *)
Definition cast {T : Type} (F : T -> Type) {x y : T} (eq : thunkP (x = y))
                {DEC : unit -> Decidable (x = y)}:
                F x -> F y :=
  fun a => eq_rect x F a y (@reprove _ (DEC ()) eq).

Lemma cast_eq T F (x : T) (eq : thunkP (x = x)) `{forall x y, Decidable (x = y)} a :
  cast F eq a = a.
Proof. by rewrite /cast -Eqdep_dec.eq_rect_eq_dec. Qed.

(** Some operations on streams **)

(** Concatenation of a list and a stream **)
Fixpoint app_str {A:Type} (l:list A) (s:Stream A) :=
  match l with
    | nil => s
    | cons t q => Cons t (app_str q s)
  end.

Infix "++" := app_str (right associativity, at level 60).

Lemma app_str_app_assoc {A:Type} (l1 l2:list A) (s:Stream A) :
  l1 ++ (l2 ++ s) = (l1 ++ l2) ++ s.
Proof. induction l1 as [|?? IH]=>//=. rewrite IH //. Qed.

(** The type of a non initial state: the type of semantic values associated
   with the last symbol of this state. *)
Definition noninitstate_type state :=
  symbol_semantic_type (last_symb_of_non_init_state state).

(** The stack of the automaton : it can be either nil or contains a non
    initial state, a semantic value for the symbol associted with this state,
    and a nested stack. **)
Definition stack := list (sigT noninitstate_type). (* eg. list {state & state_type state} *)

Section Interpreter.

Hypothesis safe: safe.

(* Properties of the automaton deduced from safety validation. *)
Proposition shift_head_symbs: shift_head_symbs.
Proof. pose proof safe; unfold ValidSafe.safe in H; intuition. Qed.
Proposition goto_head_symbs: goto_head_symbs.
Proof. pose proof safe; unfold ValidSafe.safe in H; intuition. Qed.
Proposition shift_past_state: shift_past_state.
Proof. pose proof safe; unfold ValidSafe.safe in H; intuition. Qed.
Proposition goto_past_state: goto_past_state.
Proof. pose proof safe; unfold ValidSafe.safe in H; intuition. Qed.
Proposition reduce_ok: reduce_ok.
Proof. pose proof safe; unfold ValidSafe.safe in H; intuition. Qed.

Variable init : initstate.

(** The top state of a stack **)
Definition state_of_stack (stack:stack): state :=
  match stack with
    | [] => init
    | existT _ s _::_ => s
  end.

(** The stack of states of an automaton stack **)
Definition state_stack_of_stack (stack:stack) :=
  (List.map
    (fun cell:sigT noninitstate_type => singleton_state_pred (projT1 cell))
    stack ++ [singleton_state_pred init])%list.

(** The stack of symbols of an automaton stack **)
Definition symb_stack_of_stack (stack:stack) :=
  List.map
    (fun cell:sigT noninitstate_type => last_symb_of_non_init_state (projT1 cell))
    stack.

(** The stack invariant : it basically states that the assumptions on the
    states are true. **)
Inductive stack_invariant: stack -> Prop :=
  | stack_invariant_constr:
    forall stack,
      prefix      (head_symbs_of_state (state_of_stack stack))
                  (symb_stack_of_stack stack) ->
      prefix_pred (head_states_of_state (state_of_stack stack))
                  (state_stack_of_stack stack) ->
      stack_invariant_next stack ->
      stack_invariant stack
with stack_invariant_next: stack -> Prop :=
  | stack_invariant_next_nil:
      stack_invariant_next []
  | stack_invariant_next_cons:
    forall state_cur st stack_rec,
      stack_invariant stack_rec ->
      stack_invariant_next (existT _ state_cur st::stack_rec).

(** [pop] pops some symbols from the stack. It returns the popped semantic
    values using [sem_popped] as an accumulator and discards the popped
    states.**)
Fixpoint pop (symbols_to_pop:list symbol) {A:Type} (stk:stack) :
  thunkP (prefix symbols_to_pop (symb_stack_of_stack stk)) ->
  forall (action:arrows_right A (map symbol_semantic_type symbols_to_pop)),
    stack * A.
unshelve refine
  (match symbols_to_pop
      return
         (thunkP (prefix symbols_to_pop (symb_stack_of_stack stk))) ->
         forall (action:arrows_right A (map _ symbols_to_pop)), stack * A
   with
     | [] => fun _ action => (stk, action)
     | t::q => fun Hp action =>
       match stk
          return thunkP (prefix (t::q) (symb_stack_of_stack stk)) -> stack * A
       with
         | existT _ state_cur sem::stack_rec => fun Hp =>
           let sem_conv := cast symbol_semantic_type _ sem in
           pop q _ stack_rec _ (action sem_conv)
         | [] => fun Hp => False_rect _ _
       end Hp
   end).
Proof.
  - simpl in Hp. clear -Hp. abstract (intros _ ; specialize (Hp I); now inversion Hp).
  - clear -Hp. abstract (specialize (Hp I); now inversion Hp).
  - simpl in Hp. clear -Hp. abstract (intros _ ; specialize (Hp I); now inversion Hp).
Defined.

(* Equivalent declarative specification for pop, so that we avoid
   (part of) the dependent types nightmare. *)
Inductive pop_spec {A:Type} :
    forall (symbols_to_pop:list symbol) (stk : stack)
           (action : arrows_right A (map symbol_semantic_type symbols_to_pop))
           (stk' : stack) (sem : A),
      Prop :=
  | Nil_pop_spec stk sem : pop_spec [] stk sem stk sem
  | Cons_pop_spec symbols_to_pop st stk action sem stk' res :
      pop_spec symbols_to_pop stk (action sem) stk' res ->
      pop_spec (last_symb_of_non_init_state st::symbols_to_pop)
               (existT _ st sem :: stk) action stk' res.

Lemma pop_spec_ok {A:Type} symbols_to_pop stk Hp action stk' res:
  pop symbols_to_pop stk Hp action = (stk', res) <->
  pop_spec (A:=A) symbols_to_pop stk action stk' res.
Proof.
  revert stk Hp action.
  induction symbols_to_pop as [|t symbols_to_pop IH]=>stk Hp action /=.
  - split.
    + intros [= <- <-]. constructor.
    + intros H. inversion H. by subst_existT.
  - destruct stk as [|[st sem]]=>/=; [by destruct pop_subproof0|].
    remember (pop_subproof t symbols_to_pop stk st Hp) as EQ eqn:eq. clear eq.
    generalize EQ. revert Hp action. rewrite <-(EQ I)=>Hp action ?.
    rewrite cast_eq. rewrite IH. split.
    + intros. by constructor.
    + intros H. inversion H. by subst_existT.
Qed.


Lemma pop_preserves_invariant symbols_to_pop stk Hp A action :
  stack_invariant stk ->
  stack_invariant (fst (pop symbols_to_pop stk Hp (A:=A) action)).
Proof.
  revert stk Hp A action. induction symbols_to_pop as [|t q IH]=>//=.
  intros stk Hp A action Hi.
  destruct Hi as [stack Hp' Hpp [|state st stk']].
  - destruct pop_subproof0.
  - now apply IH.
Qed.

Lemma pop_state_valid symbols_to_pop stk Hp A action lpred :
  prefix_pred lpred (state_stack_of_stack stk) ->
  let stk' := fst (pop symbols_to_pop stk Hp (A:=A) action) in
  state_valid_after_pop (state_of_stack stk') symbols_to_pop lpred.
Proof.
  revert stk Hp A action lpred. induction symbols_to_pop as [|t q IH]=>/=.
  - intros stk Hp A a lpred Hpp. destruct lpred as [|pred lpred]; constructor.
    inversion Hpp as [|? lpred' ? pred' Himpl Hpp' eq1 eq2]; subst.
    specialize (Himpl (state_of_stack stk)).
    destruct (pred' (state_of_stack stk)) as [] eqn:Heqpred'=>//.
    destruct stk as [|[]]; simpl in *.
    + inversion eq2; subst; clear eq2.
      unfold singleton_state_pred in Heqpred'.
      now rewrite compare_refl in Heqpred'; discriminate.
    + inversion eq2; subst; clear eq2.
      unfold singleton_state_pred in Heqpred'.
      now rewrite compare_refl in Heqpred'; discriminate.
  - intros stk Hp A a lpred Hpp. destruct stk as [|[] stk]=>//=.
    + destruct pop_subproof0.
    + destruct lpred as [|pred lpred]; [by constructor|].
      constructor. apply IH. by inversion Hpp.
Qed.

(** [step_result] represents the result of one step of the automaton : it can
    fail, accept or progress. [Fail_sr] means that the input is incorrect.
    [Accept_sr] means that this is the last step of the automaton, and it
    returns the semantic value of the input word. [Progress_sr] means that
    some progress has been made, but new steps are needed in order to accept
    a word.

    For [Accept_sr] and [Progress_sr], the result contains the new input buffer.

    [Fail_sr] means that the input word is rejected by the automaton. It is
    different to [Err] (from the error monad), which mean that the automaton is
    bogus and has perfomed a forbidden action. **)
Inductive step_result :=
  | Fail_sr: step_result
  | Accept_sr: symbol_semantic_type (NT (start_nt init)) -> Stream token -> step_result
  | Progress_sr: stack -> Stream token -> step_result.

(** [reduce_step] does a reduce action :
   - pops some elements from the stack
   - execute the action of the production
   - follows the goto for the produced non terminal symbol **)
Definition reduce_step stk prod (buffer : Stream token)
        (Hval : thunkP (valid_for_reduce (state_of_stack stk) prod))
        (Hi : stack_invariant stk)
  : step_result.
refine
  ((let '(stk', sem) as ss := pop (prod_rhs_rev prod) stk _ (prod_action prod)
      return thunkP (state_valid_after_pop (state_of_stack (fst ss)) _ _) -> _
    in fun Hval' =>
    match goto_table (state_of_stack stk') (prod_lhs prod) as goto
      return (thunkP (goto = _ -> _ : Prop)) -> _
    with
    | Some (exist _ state_new e) => fun _ =>
      let sem := eq_rect _ _ sem _ e in
      Progress_sr (existT noninitstate_type state_new sem::stk') buffer
    | None => fun Hval =>
      let sem := cast symbol_semantic_type _ sem in
      Accept_sr sem buffer
    end (fun _ => proj2 (Hval I) _ (Hval' I)))
   (fun _ => pop_state_valid _ _ _ _ _ _ _)).
Proof.
  - clear -Hi Hval.
    abstract (intros _; destruct Hi; eapply prefix_ass; [by apply Hval|eassumption]).
  - clear -Hval.
    abstract (intros _; f_equal; specialize (Hval I eq_refl); destruct stk' as [|[]]=>//).
  - clear -Hi. abstract by destruct Hi.
Defined.

Lemma reduce_step_stack_invariant_preserved stk prod buffer Hv Hi stk' buffer':
  reduce_step stk prod buffer Hv Hi = Progress_sr stk' buffer' ->
  stack_invariant stk'.
Proof.
  unfold reduce_step.
  match goal with
  | |- context [pop ?symbols_to_pop stk ?Hp ?action] =>
    assert (Hi':=pop_preserves_invariant symbols_to_pop stk Hp _ action Hi);
    generalize (pop_state_valid symbols_to_pop stk Hp _ action)
  end.
  destruct pop as [stk0 sem]=>/=. simpl in Hi'. intros Hv'.
  assert (Hgoto1:=goto_head_symbs (state_of_stack stk0) (prod_lhs prod)).
  assert (Hgoto2:=goto_past_state (state_of_stack stk0) (prod_lhs prod)).
  match goal with | |- context [fun _ : True => ?X] => generalize X end.
  destruct goto_table as [[state_new e]|] eqn:EQgoto=>//.
  intros _ [= <- <-]. constructor=>/=.
  - constructor. eapply prefix_ass. apply Hgoto1. by destruct Hi'.
  - unfold state_stack_of_stack; simpl; constructor.
    + intros ?. by destruct singleton_state_pred.
    + eapply prefix_pred_ass. apply Hgoto2. by destruct Hi'.
  - by constructor.
Qed.

(** One step of parsing. **)
Definition step stk buffer (Hi : stack_invariant stk): step_result :=
  match action_table (state_of_stack stk) as a return
    thunkP
      match a return Prop with
      | Default_reduce_act prod => _
      | Lookahead_act awt => _
      end -> _
  with
  | Default_reduce_act prod => fun Hv =>
    reduce_step stk prod buffer Hv Hi
  | Lookahead_act awt => fun Hv =>
    match Streams.hd buffer with
    | existT _ term sem =>
      match awt term as a return
        thunkP match a return Prop with Reduce_act p => _ | _ => _ end -> _
      with
      | Shift_act state_new e => fun _ =>
        let sem_conv := eq_rect _ symbol_semantic_type sem _ e in
        Progress_sr (existT noninitstate_type state_new sem_conv::stk)
                    (Streams.tl buffer)
      | Reduce_act prod => fun Hv =>
        reduce_step stk prod buffer Hv Hi
      | Fail_act => fun _ =>
        Fail_sr
      end (fun _ => Hv I term)
    end
  end (fun _ => reduce_ok _).

Lemma step_stack_invariant_preserved stk buffer Hi stk' buffer':
  step stk buffer Hi = Progress_sr stk' buffer' ->
  stack_invariant stk'.
Proof.
  unfold step.
  generalize (reduce_ok (state_of_stack stk))=>Hred.
  assert (Hshift1 := shift_head_symbs (state_of_stack stk)).
  assert (Hshift2 := shift_past_state (state_of_stack stk)).
  destruct action_table as [prod|awt]=>/=.
  - eauto using reduce_step_stack_invariant_preserved.
  - destruct (Streams.hd buffer) as [term sem].
    generalize (Hred term). clear Hred. intros Hred.
    specialize (Hshift1 term). specialize (Hshift2 term).
    destruct (awt term) as [state_new e|prod|]=>//.
    + intros [= <- <-]. constructor=>/=.
      * constructor. eapply prefix_ass. apply Hshift1. by destruct Hi.
      * unfold state_stack_of_stack; simpl; constructor.
        -- intros ?. by destruct singleton_state_pred.
        -- eapply prefix_pred_ass. apply Hshift2. by destruct Hi.
      * by constructor.
    + eauto using reduce_step_stack_invariant_preserved.
Qed.

(** The parsing use a [nat] parameter [n_steps], so that we do not have to prove
    terminaison, which is difficult. So the result of a parsing is either
    a failure (the automaton has rejected the input word), either a timeout
    (the automaton has spent all the given [n_steps]), either a parsed semantic
    value with a rest of the input buffer.
**)
Inductive parse_result :=
  | Fail_pr: parse_result
  | Timeout_pr: parse_result
  | Parsed_pr: symbol_semantic_type (NT (start_nt init)) -> Stream token -> parse_result.

Fixpoint parse_fix stk buffer n_steps (Hi : stack_invariant stk): parse_result:=
  match n_steps return _ with
  | O => Timeout_pr
  | S it =>
    match step stk buffer Hi as r
          return (forall stk' (buffer' : Stream token), r = _ -> _) -> _
    with
    | Fail_sr => fun _ => Fail_pr
    | Accept_sr t buffer_new => fun _ => Parsed_pr t buffer_new
    | Progress_sr s buffer_new => fun Hi =>
      parse_fix s buffer_new it (Hi s _ eq_refl)
    end (step_stack_invariant_preserved _ _ _)
  end.

Definition parse (buffer : Stream token) (n_steps : nat): parse_result.
refine
  (parse_fix [] buffer n_steps _).
Proof.
  abstract (repeat constructor; intros; by destruct singleton_state_pred).
Defined.

End Interpreter.

Arguments Fail_sr [init].
Arguments Accept_sr [init] _ _.
Arguments Progress_sr [init] _ _.

Arguments Fail_pr [init].
Arguments Timeout_pr [init].
Arguments Parsed_pr [init] _ _.

End Make.

Module Type T(A:Automaton.T).
  Include (Make A).
End T.
