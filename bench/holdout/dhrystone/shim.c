/* Held-out harness shim for Dhrystone 2.1. Dhry_init()/Dhry_one_run() are
   the HOLDOUT PORT split of upstream dhry_1.c's main() (see the header
   comment there): Dhry_init() does the one-time setup, Dhry_one_run() is
   one iteration of the original measurement loop, called HOLDOUT_REPS
   times by main_wrapper.c.

   Classic Dhrystone has no verify_benchmark() of its own; upstream's
   main() just printed "final values ... should be ..." for the operator
   to eyeball. holdout_verify() below replicates that comparison as an
   actual pass/fail check against the same expected values, with one
   rep-count-dependent term: Arr_2_Glob[8][7] accumulates +1 per
   Dhry_one_run() call (via Proc_8), so upstream's own comment
   "should be: Number_Of_Runs + 10" becomes "10 + run_count" here. */

#include "dhry.h"

extern Rec_Pointer Ptr_Glob, Next_Ptr_Glob;
extern int         Int_Glob;
extern Boolean     Bool_Glob;
extern char        Ch_1_Glob, Ch_2_Glob;
extern int         Arr_1_Glob[50];
extern int         Arr_2_Glob[50][50];

extern void Dhry_init(void);
extern void Dhry_one_run(void);

static unsigned run_count;

int
holdout_init(void)
{
  Dhry_init();
  run_count = 0;
  return 0;
}

void
holdout_body(void)
{
  Dhry_one_run();
  run_count++;
}

int
holdout_verify(void)
{
  int ok = 1;

  ok = ok && (Int_Glob == 5);
  ok = ok && (Bool_Glob == 1);
  ok = ok && (Ch_1_Glob == 'A');
  ok = ok && (Ch_2_Glob == 'B');
  ok = ok && (Arr_1_Glob[8] == 7);
  ok = ok && (Arr_2_Glob[8][7] == (int)(10 + run_count));

  ok = ok && (Ptr_Glob->Discr == Ident_1);
  ok = ok && (Ptr_Glob->variant.var_1.Enum_Comp == Ident_3);
  ok = ok && (Ptr_Glob->variant.var_1.Int_Comp == 17);
  ok = ok && (strcmp(Ptr_Glob->variant.var_1.Str_Comp,
                      "DHRYSTONE PROGRAM, SOME STRING") == 0);

  ok = ok && (Next_Ptr_Glob->Discr == Ident_1);
  ok = ok && (Next_Ptr_Glob->variant.var_1.Enum_Comp == Ident_2);
  ok = ok && (Next_Ptr_Glob->variant.var_1.Int_Comp == 18);
  ok = ok && (strcmp(Next_Ptr_Glob->variant.var_1.Str_Comp,
                      "DHRYSTONE PROGRAM, SOME STRING") == 0);

  return ok;
}
