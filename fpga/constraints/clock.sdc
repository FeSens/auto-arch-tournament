// Gowin timing constraint for the V2 FPGA fitness (tools/eval/gowin.py).
// The target only steers timing-driven optimization; the score is the
// Actual Fmax from the timing report. Fixed for every design.
create_clock -name clock -period 5 [get_ports {clock}]
