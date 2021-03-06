(* Evaluation.
   
   Evaluation works through explicit continuation passing style. It maintains
   three different flavors of state:

   - Lexical state is the local, statically scoped state. Each method has its own
     scoped state so a caller's state is not automatically visible within a
     method it calls -- unless it is explicitly captured. Local variables reside
     in the scoped state.
   - Dynamic state is similar to scoped state in that it is scoped but changes
     made to a caller's dynamic state are visible to a method it calls. For
     instance, a signal handler set up in a method are active within the methods
     it calls.
   - Pervasive state state is unscoped and threaded throughout the evaluation. It
     records mutable state, for instance. So not only are changes made by a
     caller visible to the methods it calls, changes made by a called method are
     visible to the caller.

   All these flavors of state are immutable. You don't change the pervasive state,
   you create a new changed version and pass it on. This way all effects are
   explicit. *)
structure Eval = struct

  structure V = Value;
  structure D = Dict;

  (* The id of the destination of a non-local escape. *)
  type escape_uid = V.uid;

  (* The pervasice, non-scoped, state. This flows linearly through the evaluation
     independent of scope and control flow -- for instance, leaving a scope can
     restore a previous scope state but nothing can restore a previous pervasive
     state. *)
  type pervasive_state = {
    (* The stream of object identity. *)
    uid_stream: V.uid_stream,
    (* Mapping from object ids to object state. *)
    objects: (V.uid, V.object_state) D.dict,
    (* A log that values can be written to for debug and test purposes. *)
    log: V.value list
  };

  val initial_pervasive_state : pervasive_state = {
    uid_stream = V.uid_stream_start,
    objects = D.empty,
    log = []
  };

  (* Returns a new unique id pulled from the given pervasive state as well as a
     new pervasive state to use from here on. *)
  fun genuid (p as {uid_stream=is0, ...} : pervasive_state) =
    let
      val (uid, is1) = V.genuid is0
    in
      (uid, {uid_stream=is1, objects=(#objects p), log=(#log p)})
    end;

  (* Returns a new pervasive state where the state of the object with the given
     id is the given value. *)
  fun set_object (p as {objects=os0, ...} : pervasive_state) oid state =
    let
      val os1 = D.set os0 oid state
    in
      {objects=os1, uid_stream=(#uid_stream p), log=(#log p)}
    end;

  (* Returns the state of the given value. Unlike set_object this works on
     non-objects, the result will be the empty object state. *)
  fun get_object ({objects=os, ...} : pervasive_state) (V.Object oid) =
      (case (D.get os oid)
         of (SOME state) => state
          | NONE => V.empty_object_state)
    | get_object _ _ = V.empty_object_state
  ;

  fun append_log (p as {log=l0, ...} : pervasive_state) entry =
    let
      val l1 = l0 @ [entry]
    in
      {log=l1, objects=(#objects p), uid_stream=(#uid_stream p)}
    end;

  (* A local continuation, the next step during normal evaluation. Continuations
     always continue in the scope they captured when they were created whereas
     the pervasive state is always passed in. *)
  type continuation = V.value -> pervasive_state -> V.value * pervasive_state;

  val toplevel_lexical_scope = V.LexicalScope {
    lookup_variable = []
  };

  (* Returns a new scope state where the given name is bound to the given value. *)
  fun push_binding scope name value =
    let
      val V.LexicalScope {lookup_variable=outer} = scope
    in
      V.LexicalScope {lookup_variable=(name, value)::outer}
    end;

  (* An escape continuation, the next step in performing a non-local escape.
     The id identifies the destination we're trying to escape to. *)
  type escape = escape_uid -> continuation;

  (* This should probably raise an exception actually, escaping to somewhere
     that doesn't exist. *)
  fun toplevel_escape target_id value pervasive =
    (value, pervasive);

  (* Dynamically scoped state, that is, state that propagats from caller to
     callee but not the other way. *)
  type dynamic_scope_state = {
    (* The currently active non-local continuation. *)
    escape: escape
  };

  val toplevel_dynamic_scope_state : dynamic_scope_state = {
    escape = toplevel_escape
  };

  (* Returns a new dynamic scope state with the given escape continuation as the
     active escape. *)
  fun set_escape ({...} : dynamic_scope_state) value
    = {escape=value};

  exception UnresolvedVariable of V.value;

  (* Executes a single evaluation step. *)
  fun step expr continue (state as (_, _, p0)) = 
    case expr
      of V.Literal value 
      => (continue value p0)
       | V.WithEscape (name, body)
      => step_with_escape name body continue state
       | V.FireEscape (target_id, body)
      => step_fire_escape target_id body state
       | V.Ensure (body, block)
      => step_ensure body block continue state
       | V.Variable name
      => step_variable name continue state
       | V.Sequence exprs
      => step_sequence exprs continue state
       | V.LocalBinding (name, value, body)
      => step_local_binding name value body continue state
       | V.NewObject
      => step_new_object continue state
       | V.NewField
      => step_new_field continue state
       | V.GetField (field, object)
      => step_get_field field object continue state
       | V.SetField (field, object, value)
      => step_set_field field object value continue state
       | V.Log value
      => step_log value continue state
       | V.CallLambda (lambda, value)
      => step_call_lambda lambda value continue state

  and step_with_escape name body continue (s0, d0, p0) =
    let
      (* Acquire an ie for this escape. This'll be used to identify this as the
         destination for the escape lambda. *)
      val (escape_id, p1) = genuid p0
      (* Grab the non_local that was in effect immediately before this
         expression. *)
      val outer_escape = (#escape d0)
      (* The new topmost non-local handler that will be in effect for the body. *)
      fun escape target_id value p2 =
        if (target_id = escape_id)
          (* If someone escapes non-locally with this escape as the target we
             simply continue on from immediately after this. *)
          then (continue value p2)
          (* If they're escaping to another target it must be outside this
             escape so we just let it keep going through the next outer
             nonlocal and discard this expression and its continuation. *)
          else (outer_escape target_id value p2)
      (* Install the new non-local. *)
      val d1 = set_escape d0 escape
      (* Create a binding for the symbol. *)
      val param = V.String "value"
      val scope = toplevel_lexical_scope
      val body = V.FireEscape (escape_id, V.Variable param)
      val escape_lambda = V.Lambda (scope, [param], body)
      val s1 = push_binding s0 name escape_lambda
    in
      step body continue (s1, d1, p1)
    end

  and step_fire_escape target_id body (state as (_, d0, _)) =
    let
      (* This is the non-local continuation we'll eventually fire. *)
      val escape = (#escape d0)
      val continue_escape = (escape target_id)
    in
      step body continue_escape state
    end

  and step_ensure body block continue (s0, d0, p0) =
    let
      val outer_escape = (#escape d0)
      (* The ensure-block is evaluated in the same dynamic scope as the one in
         which it was defined such that if it escapes itself it won't end in an
         infinite loop.

         After evaluating the ensure block we discard its result and continue
         evaluation with the value of the block such that the result value of
         the whole thing is unaffected by the ensure block.

         The pervasive state is called pa1 to reflect the fact that there are
         two paths through this code, the non-escape (a) and escape (b) path. *)
      fun continue_ensure value pa1 =
        let
          fun continue_discard_value _ =
            continue value
        in
          step block continue_discard_value (s0, d0, pa1)
        end
      (* If the body escapes we evaluate the ensure block with a continuation
         that continues escaping past this escape. As in the normal case the
         evaluation of the block happens in the same dynamic scope as the one
         in which it is defined, again to avoid looking if it escapes itself. *)
      fun escape_ensure target_id value pb1 =
        let
          val continue_outer_escape = (outer_escape target_id)
        in
          step block continue_outer_escape (s0, d0, pb1)
        end
      (* The new dynamic scope to use for the body. *)
      val d1 = set_escape d0 escape_ensure
    in
      (* After normal completion of the body we evaluate the ensure block. *)
      step body continue_ensure (s0, d1, p0)
    end

  and step_variable name continue (s0, _, p0) =
    let
      val (V.LexicalScope {lookup_variable=bindings, ...}) = s0
      fun get_binding [] = raise (UnresolvedVariable name)
        | get_binding ((n, v)::rest) =
          if (V.== n name)
            then v
            else get_binding rest
    in
      continue (get_binding bindings) p0
    end

  and step_sequence [only] continue state =
      (* A sequence of one expression is equivalent to that one expression. *)
      (step only continue state)
    | step_sequence (next::rest) continue (state as (s0, d0, p0)) =
      (* First evaluate the first expression, discard the value, then evaluate
         the rest. *)
      let
        fun continue_rest _ p1 = step_sequence rest continue (s0, d0, p1)
      in
        step next continue_rest state
      end

  and step_local_binding name value_expr body continue (state as (s0, d0, p0)) =
    let
      (* Continuation that is fired when the value has been evaluated. Binds the
         value to the binding's name and evaluates the body in that scope. *)
      fun continue_with_binding value p1 =
        let
          val s1 = push_binding s0 name value
        in
          step body continue (s1, d0, p1)
        end
    in
      step value_expr continue_with_binding state
    end

  and step_new_object continue (_, _, p0) =
    let
      (* Generate a new object id. *)
      val (oid, p1) = genuid p0
      (* Initialize the object's state. *)
      val p2 = set_object p1 oid V.empty_object_state
    in
      continue (V.Object oid) p2
    end

  and step_new_field continue (_, _, p0) =
    let
      (* Generate a new object (field) id. *)
      val (oid, p1) = genuid p0
    in
      continue (V.Field oid) p1
    end

  and step_get_field field_expr object_expr continue (state as (s0, d0, p0)) =
    let
      (* After the field key evaluate the object. *)
      fun continue_eval_object field p1 =
        let
          (* After the object access the field's value. *)
          fun continue_get_field object p2 =
            continue (get_object_field field object p2) p2
        in
          step object_expr continue_get_field (s0, d0, p1)
        end
    in
      step field_expr continue_eval_object state
    end

  (* Utility for getting a field from an object within a given pervasive state.
     If the field is not present the result is NONE. *)
  and get_object_field (V.Field fid) object p0 =
    let
      val {fields=fields, ...} = (get_object p0 object)
    in
      case (D.get fields fid)
        of (SOME v) => v
         | NONE => V.Null
    end

  (* Returns a new pervasive state identical to the previous one except that
     the given field on the given object has the given value. *)
  and set_object_field (V.Field fid) (object as (V.Object oid)) value p0 =
    let
      val old_state = get_object p0 object
      val new_state = V.set_object_state_field old_state fid value
    in
      set_object p0 oid new_state
    end

  and step_set_field field_expr object_expr value_expr continue (s0, d0, p0) =
    let
      fun continue_eval_object field p1 =
        let
          fun continue_eval_value object p2 =
            let
              fun continue_set_field value p3 =
                continue value (set_object_field field object value p3)
            in
              step value_expr continue_set_field (s0, d0, p2)
            end
        in
          step object_expr continue_eval_value (s0, d0, p1)
        end
    in
      step field_expr continue_eval_object (s0, d0, p0)
    end

  and step_log value_expr continue (s0, d0, p0) =
    let
      fun continue_log value p1 =
        let
          val p2 = append_log p1 value
        in
          continue value p2
        end
    in
      step value_expr continue_log (s0, d0, p0)
    end

  and step_call_lambda lambda_expr value_expr continue (s0, d0, p0) =
    let
      fun continue_eval_value (V.Lambda (sl0, [param], lambda_body)) p1 =
        let
          fun continue_call_lambda value p2 =
            let
              val sl1 = push_binding sl0 param value
            in
              step lambda_body continue (sl1, d0, p2)
            end
        in
          step value_expr continue_call_lambda (s0, d0, p1)
        end
    in
      step lambda_expr continue_eval_value (s0, d0, p0)
    end

  fun yield_value value pervasive = (value, pervasive);

  val initial_state = (toplevel_lexical_scope,
    toplevel_dynamic_scope_state, initial_pervasive_state)

  (* Evaluates the given parsed expression, returning a pair of the result value
     and the pervasive state in which the value should be interpreted. *)
  fun eval expr = step expr yield_value initial_state;

end;
