let pi = acos (-1.)

let freq_of_note n = 440. *. (2. ** ((float n -. 69.) /. 12.))

class type synth =
object
  method set_volume : float -> unit

  method note_on : int -> float -> unit

  method note_off : int -> float -> unit

  method synth : float -> float array array -> int -> int -> float array array -> unit

  method reset : unit
end

(* Global state and note state. *)
class virtual ['gs,'ns] base =
object (self)
  val mutable volume = 1.

  method set_volume v = volume <- v

  val mutable state = None

  method state =
    match state with
      | Some s -> s
      | None -> assert false

  val mutable notes = []

  method reset = notes <- []

  method virtual state_init : 'gs

  method virtual note_init : int -> float -> 'ns

  method init =
    state <- Some (self#state_init)

  initializer
    self#init

  method note_on n v =
    (* Limit the number of notes for now. TODO: parameter *)
    (* if List.length notes > 16 then notes <- List.rev (List.tl (List.rev notes)); *)
    notes <- (n, self#note_init n v)::notes

  method note_off n (v:float) =
    (* TODO: remove only one note *)
    notes <- List.filter (fun (m, _) -> m <> n) notes

  method synth_note_mono (gs:'gs) (ns:'ns) (freq:float) (buf:float array) (ofs:int) (len:int) = gs

  method synth_note gs ns freq buf ofs len =
    let s = self#synth_note_mono gs ns freq buf.(0) ofs len in
      for c = 1 to Array.length buf - 1 do
        Float_pcm.float_blit buf.(0) ofs buf.(c) ofs len
      done;
      s

  (* tmpbuf is used to generate notes separately. It should be of length at
   * least len. *)
  method synth freq buf ofs len tmpbuf =
    let gs = ref self#state in
      List.iter
        (fun (_, ns) ->
           let gs' = self#synth_note self#state ns freq tmpbuf 0 len in
             Float_pcm.add buf ofs tmpbuf 0 len;
             gs := gs'
        ) notes;
      state <- Some !gs

  method adsr adsr st buf ofs len =
    let a,(d:int),s,(r:int) = adsr in
    let state, state_pos = st in
      match state with
        | 0 ->
            let fa = float a in
              for c = 0 to Array.length buf - 1 do
                let bufc = buf.(c) in
                for i = 0 to min len (a - state_pos) - 1 do
                  bufc.(ofs + i) <- float (state_pos + i) /. fa *. bufc.(ofs + i)
                done
              done;
              if len < a - state_pos then
                0, state_pos + len
              else
                self#adsr adsr (1,0) buf (ofs + a - state_pos) (len - (a - state_pos))
        | 1 ->
            let fd = float d in
              for c = 0 to Array.length buf - 1 do
                let bufc = buf.(c) in
                for i = 0 to min len (d - state_pos) - 1 do
                  bufc.(ofs + i) <- (1. -. float (state_pos + i) /. fd *. (1. -. s)) *. bufc.(ofs + i)
                done
              done;
              if len < d - state_pos then
                1, state_pos + len
              else
                self#adsr adsr (2,0) buf (ofs + d - state_pos) (len - (d - state_pos))
        | 2 ->
            Float_pcm.multiply buf ofs len s;
            st
        | 3 ->
            let fr = float r in
              for c = 0 to Array.length buf - 1 do
                let bufc = buf.(c) in
                for i = 0 to min len (r - state_pos) - 1 do
                  bufc.(ofs + i) <- s *. (1. -. float (state_pos + i) /. fr) *. bufc.(ofs + i)
                done
              done;
              if len < r - state_pos then
                3, state_pos + len
              else
                self#adsr adsr (4,0) buf (ofs + r - state_pos) (len - (r - state_pos))
        | 4 ->
            Float_pcm.blankify buf ofs len;
            st
        | _ -> assert false
end

type adsr_state = int * int (* state (A/D/S/R/dead), position in the state *)

(** Initial adsr state. *)
let adsr_init () = 0, 0

(** Convert adsr in seconds to samples. *)
let samples_of_adsr (a,d,s,r) =
  Fmt.samples_of_seconds a, Fmt.samples_of_seconds d, s, Fmt.samples_of_seconds r

type simple_gs = unit
(* Period is 1. *)
type simple_ns =
    {
      mutable simple_phase : float;
      simple_freq : float;
      simple_ampl : float;
      mutable simple_adsr : adsr_state;
    }

class simple ?adsr f =
object (self)
  inherit [simple_gs, simple_ns] base as super

  val adsr =
    match adsr with
      | Some adsr -> Some (samples_of_adsr adsr)
      | None -> None

  method state_init = ()

  method note_init n v =
    {
      simple_phase = 0.;
      simple_freq = freq_of_note n;
      simple_ampl = v;
      simple_adsr = adsr_init ();
    }

  method note_off n v =
    if adsr = None then
      super#note_off n v
    else
      List.iter (fun (nn, ns) -> if nn = n then ns.simple_adsr <- (3,0)) notes

  method synth_note_mono gs ns freq buf ofs len =
    let phase i = ns.simple_phase +. float i /. freq *. ns.simple_freq in
      for i = ofs to ofs + len - 1 do
        buf.(i) <- volume *. ns.simple_ampl *. f (phase i)
      done;
      ns.simple_phase <- fst (modf (phase len));
      match adsr with
        | Some adsr ->
            ns.simple_adsr <- self#adsr adsr ns.simple_adsr [|buf|] ofs len;
            gs
        | None -> gs

  method synth freq buf ofs len tmpbuf =
    if adsr <> None then
      notes <- List.filter (fun (_, ns) -> fst ns.simple_adsr < 4) notes;
    super#synth freq buf ofs len tmpbuf
end

class sine ?adsr () = object inherit simple ?adsr (fun x -> sin (x *. 2. *. pi)) end

class square ?adsr () = object inherit simple ?adsr (fun x -> let x = fst (modf x) in if x < 0.5 then 1. else -1.) end

class saw ?adsr () =
object
  inherit simple ?adsr
    (fun x ->
       let x = fst (modf x) in
         if x < 0.5 then
           4. *. x -. 1.
         else
           4. *. (1. -. x) -. 1.
    )
    as super

  method note_init n v = { (super#note_init n v) with simple_phase = 0.25 }
end

let hammond_coef = [|0.5; 1.5; 1.; 2.; 3.; 4.; 5.; 6.; 8.|]

class hammond ?adsr drawbar =
object
  inherit simple ?adsr
    (fun x ->
       let y = ref 0. in
         for i = 0 to 8 do
           y := !y +. sin (x *. 2. *. pi *. hammond_coef.(i) *. drawbar.(i) /. 10.)
         done;
    !y)
end

(*
(** Read a GUS pat file. *)
let read_pat file =
  let fd = Unix.openfile file [Unix.O_RDONLY] 0o644 in
  let read_bytes n =
    let s = String.create n in
      assert (Unix.read fd s 0 n = n);
      s
  in
  let read_string n =
    let s = read_bytes n ^ "\000" in
    let i = String.index s '\000' in
      String.sub s 0 i
  in
  let advance n = ignore (read_bytes n) in
  let read_byte () = int_of_char (read_bytes 1).[0] in
  let read_uword () =
    let b1 = read_byte () in
    let b2 = read_byte () in
      b1 + 0x100 * b2
  in
  let read_word () =
    let b = read_uword () in
      if b > 32767 then b - 65536 else b
  in
  let read_int () =
    let b1 = read_byte () in
    let b2 = read_byte () in
    let b3 = read_byte () in
    let b4 = read_byte () in
      b1 + 0x100 * b2 + 0x10000 * b3 + 0x1000000 * b4
  in
    (* Identification string. *)
    assert (read_bytes 22 = "GF1PATCH110\000ID#000002\000");
    (* Copyright info. *)
    advance 60;
    (* Number of instruments. *)
    assert (read_byte () = 1);
    (* Volume. *)
    let vol = read_word () in
    advance 40;
    (* Instrument number. *)
    let num_instr = read_word () in
    (* advance 4; (* TODO: hum hum *) *)
    (* Instrument name. *)
    let name = read_string 16 in
    (* Instrument size and layers count. *)
    advance 45;
    (* First layer. *)
    advance 6;
    let num_samples = read_byte () in
    advance 40;
    for i = 0 to num_samples - 1 do
      (* Sample name. *)
      let sample_name = read_string 8 in
        Printf.printf "sample: %s\n%!" sample_name
    done;
    Printf.printf "instr %d vol %d, %s, %d samples\n%!" num_instr vol name num_samples;
    Unix.close fd

let () =
  read_pat "/usr/share/midi/freepats/Tone_000/000_Acoustic_Grand_Piano.pat";
  exit 69
*)