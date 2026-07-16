/*
 ****************************************************************************
 *
 *                   "DHRYSTONE" Benchmark Program
 *                   -----------------------------
 *
 *  Version:    C, Version 2.1
 *
 *  File:       dhry_1.c (part 2 of 3)
 *
 *  Date:       May 25, 1988
 *
 *  Author:     Reinhold P. Weicker
 *
 ****************************************************************************
 *
 * HOLDOUT PORT: this file has been adapted for the auto-arch-tournament
 * bare-metal held-out benchmark harness (bench/holdout/). Upstream's
 * main() combined one-time setup, the timed "for (Run_Index ...)"
 * measurement loop, UNIX times()/printf/scanf instrumentation, and a
 * results report in a single function. Bare metal has none of stdio,
 * scanf, or times(2), and this harness needs separate init/body entry
 * points so bench/holdout/dhrystone/shim.c and
 * bench/holdout/support/main_wrapper.c can bracket the timed region with
 * MMIO markers and repeat the body HOLDOUT_REPS times. main() below is
 * split into:
 *   - Dhry_init():    the one-time "Initializations" block that ran
 *                      before the loop (malloc + Ptr_Glob/Str_1_Loc
 *                      setup). Called once from shim.c's holdout_init().
 *   - Dhry_one_run():  the loop body, run once per call, statement-for-
 *                      statement identical to one iteration of the
 *                      original "for" loop. Called HOLDOUT_REPS times
 *                      from the wrapper's timed loop.
 * The only content change inside the timed body is the branch upstream
 * marks "then, not executed" (dead code kept only to discourage the
 * compiler from eliminating the surrounding statements): it referenced
 * the vanished `Run_Index` loop variable, so a static call counter
 * (Holdout_run_counter) stands in for it here, with the same
 * never-taken control flow and the same statement shape. All
 * printf/scanf/times() instrumentation and the results report were
 * removed; verification is done by holdout_verify() in shim.c, which
 * inspects the same final-state globals the upstream report printed.
 */

#include "dhry.h"
#include <stdlib.h>

/* Global Variables: */

Rec_Pointer     Ptr_Glob,
                Next_Ptr_Glob;
int             Int_Glob;
Boolean         Bool_Glob;
char            Ch_1_Glob,
                Ch_2_Glob;
int             Arr_1_Glob [50];
int             Arr_2_Glob [50] [50];

Enumeration     Func_1 ();
  /* forward declaration necessary since Enumeration may not simply be int */

#define REG
        /* REG becomes defined as empty */
        /* i.e. no register variables   */
        /* HOLDOUT PORT: upstream picked this via `#ifndef REG` plus a
           `Reg` flag that only fed the removed "compiled with 'register'
           attribute" printf banner; this harness never defines REG, so
           collapse the conditional to its one live branch. */

static Str_30   Str_1_Loc;
        /* HOLDOUT PORT: was a local of main(), initialized once before
           the loop and read (never written) inside it; promoted to a
           file-scope static so Dhry_one_run() can still read the value
           Dhry_init() set. */

static int Holdout_run_counter = 0;
        /* HOLDOUT PORT: stands in for the vanished `Run_Index` loop
           variable inside the dead branch below; see file header. */

void
Dhry_init (void)
/* HOLDOUT PORT: corresponds to the "Initializations" block of upstream
   main(), executed once before the measurement loop. Unchanged from
   upstream except that it no longer also seeds Arr_1_Glob (untouched;
   it never was) and drops the printf/scanf banner that followed it. */
{
  Next_Ptr_Glob = (Rec_Pointer) malloc (sizeof (Rec_Type));
  Ptr_Glob = (Rec_Pointer) malloc (sizeof (Rec_Type));

  Ptr_Glob->Ptr_Comp                    = Next_Ptr_Glob;
  Ptr_Glob->Discr                       = Ident_1;
  Ptr_Glob->variant.var_1.Enum_Comp     = Ident_3;
  Ptr_Glob->variant.var_1.Int_Comp      = 40;
  strcpy (Ptr_Glob->variant.var_1.Str_Comp,
          "DHRYSTONE PROGRAM, SOME STRING");
  strcpy (Str_1_Loc, "DHRYSTONE PROGRAM, 1'ST STRING");

  Arr_2_Glob [8][7] = 10;
        /* Was missing in published program. Without this statement,    */
        /* Arr_2_Glob [8][7] would have an undefined value.             */
        /* Warning: With 16-Bit processors and Number_Of_Runs > 32000,  */
        /* overflow may occur for this array element.                   */
}

void
Dhry_one_run (void)
/* HOLDOUT PORT: corresponds to one iteration of the upstream
   "for (Run_Index = 1; Run_Index <= Number_Of_Runs; ++Run_Index)" loop
   body. Every statement upstream marks as executed is unchanged; only
   the never-taken branch's two Run_Index reads were substituted per the
   file header comment. */
{
        One_Fifty       Int_1_Loc;
  REG   One_Fifty       Int_2_Loc;
        One_Fifty       Int_3_Loc;
  REG   char            Ch_Index;
        Enumeration     Enum_Loc;
        Str_30          Str_2_Loc;

  ++Holdout_run_counter;

  Proc_5();
  Proc_4();
    /* Ch_1_Glob == 'A', Ch_2_Glob == 'B', Bool_Glob == true */
  Int_1_Loc = 2;
  Int_2_Loc = 3;
  strcpy (Str_2_Loc, "DHRYSTONE PROGRAM, 2'ND STRING");
  Enum_Loc = Ident_2;
  Bool_Glob = ! Func_2 (Str_1_Loc, Str_2_Loc);
    /* Bool_Glob == 1 */
  while (Int_1_Loc < Int_2_Loc)  /* loop body executed once */
  {
    Int_3_Loc = 5 * Int_1_Loc - Int_2_Loc;
      /* Int_3_Loc == 7 */
    Proc_7 (Int_1_Loc, Int_2_Loc, &Int_3_Loc);
      /* Int_3_Loc == 7 */
    Int_1_Loc += 1;
  } /* while */
    /* Int_1_Loc == 3, Int_2_Loc == 3, Int_3_Loc == 7 */
  Proc_8 (Arr_1_Glob, Arr_2_Glob, Int_1_Loc, Int_3_Loc);
    /* Int_Glob == 5 */
  Proc_1 (Ptr_Glob);
  for (Ch_Index = 'A'; Ch_Index <= Ch_2_Glob; ++Ch_Index)
                           /* loop body executed twice */
  {
    if (Enum_Loc == Func_1 (Ch_Index, 'C'))
        /* then, not executed */
      {
      Proc_6 (Ident_1, &Enum_Loc);
      strcpy (Str_2_Loc, "DHRYSTONE PROGRAM, 3'RD STRING");
      Int_2_Loc = Holdout_run_counter;
      Int_Glob = Holdout_run_counter;
      }
  }
    /* Int_1_Loc == 3, Int_2_Loc == 3, Int_3_Loc == 7 */
  Int_2_Loc = Int_2_Loc * Int_1_Loc;
  Int_1_Loc = Int_2_Loc / Int_3_Loc;
  Int_2_Loc = 7 * (Int_2_Loc - Int_3_Loc) - Int_1_Loc;
    /* Int_1_Loc == 1, Int_2_Loc == 13, Int_3_Loc == 7 */
  Proc_2 (&Int_1_Loc);
    /* Int_1_Loc == 5 */
}


Proc_1 (Ptr_Val_Par)
/******************/

REG Rec_Pointer Ptr_Val_Par;
    /* executed once */
{
  REG Rec_Pointer Next_Record = Ptr_Val_Par->Ptr_Comp;
                                        /* == Ptr_Glob_Next */
  /* Local variable, initialized with Ptr_Val_Par->Ptr_Comp,    */
  /* corresponds to "rename" in Ada, "with" in Pascal           */

  structassign (*Ptr_Val_Par->Ptr_Comp, *Ptr_Glob);
  Ptr_Val_Par->variant.var_1.Int_Comp = 5;
  Next_Record->variant.var_1.Int_Comp
        = Ptr_Val_Par->variant.var_1.Int_Comp;
  Next_Record->Ptr_Comp = Ptr_Val_Par->Ptr_Comp;
  Proc_3 (&Next_Record->Ptr_Comp);
    /* Ptr_Val_Par->Ptr_Comp->Ptr_Comp
                        == Ptr_Glob->Ptr_Comp */
  if (Next_Record->Discr == Ident_1)
    /* then, executed */
  {
    Next_Record->variant.var_1.Int_Comp = 6;
    Proc_6 (Ptr_Val_Par->variant.var_1.Enum_Comp,
           &Next_Record->variant.var_1.Enum_Comp);
    Next_Record->Ptr_Comp = Ptr_Glob->Ptr_Comp;
    Proc_7 (Next_Record->variant.var_1.Int_Comp, 10,
           &Next_Record->variant.var_1.Int_Comp);
  }
  else /* not executed */
    structassign (*Ptr_Val_Par, *Ptr_Val_Par->Ptr_Comp);
} /* Proc_1 */


Proc_2 (Int_Par_Ref)
/******************/
    /* executed once */
    /* *Int_Par_Ref == 1, becomes 4 */

One_Fifty   *Int_Par_Ref;
{
  One_Fifty  Int_Loc;
  Enumeration   Enum_Loc;

  Int_Loc = *Int_Par_Ref + 10;
  do /* executed once */
    if (Ch_1_Glob == 'A')
      /* then, executed */
    {
      Int_Loc -= 1;
      *Int_Par_Ref = Int_Loc - Int_Glob;
      Enum_Loc = Ident_1;
    } /* if */
  while (Enum_Loc != Ident_1); /* true */
} /* Proc_2 */


Proc_3 (Ptr_Ref_Par)
/******************/
    /* executed once */
    /* Ptr_Ref_Par becomes Ptr_Glob */

Rec_Pointer *Ptr_Ref_Par;

{
  if (Ptr_Glob != Null)
    /* then, executed */
    *Ptr_Ref_Par = Ptr_Glob->Ptr_Comp;
  Proc_7 (10, Int_Glob, &Ptr_Glob->variant.var_1.Int_Comp);
} /* Proc_3 */


Proc_4 () /* without parameters */
/*******/
    /* executed once */
{
  Boolean Bool_Loc;

  Bool_Loc = Ch_1_Glob == 'A';
  Bool_Glob = Bool_Loc | Bool_Glob;
  Ch_2_Glob = 'B';
} /* Proc_4 */


Proc_5 () /* without parameters */
/*******/
    /* executed once */
{
  Ch_1_Glob = 'A';
  Bool_Glob = false;
} /* Proc_5 */


        /* Procedure for the assignment of structures,          */
        /* if the C compiler doesn't support this feature       */
#ifdef  NOSTRUCTASSIGN
memcpy (d, s, l)
register char   *d;
register char   *s;
register int    l;
{
        while (l--) *d++ = *s++;
}
#endif
