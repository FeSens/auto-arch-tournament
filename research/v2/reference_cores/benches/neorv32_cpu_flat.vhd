-- Flat-port shim around neorv32_cpu for the V2 Gowin Fmax bench: the CPU's
-- bus_req_t/bus_rsp_t records become plain vectors so the SystemVerilog bench
-- can instantiate it. Config: rv32im (Zicsr is built in), CPU_FAST_MUL_EN and
-- CPU_FAST_SHIFT_EN (the datasheet's fastest rv32im options), no C, no
-- caches, no counters, no debug, default register file.
library ieee;
use ieee.std_logic_1164.all;

library neorv32;
use neorv32.neorv32_package.all;

entity neorv32_cpu_flat is
  port (
    clk_i      : in  std_ulogic;
    rstn_i     : in  std_ulogic;
    irq_i      : in  std_ulogic_vector(2 downto 0);
    sleep_o    : out std_ulogic;
    ifence_o   : out std_ulogic;
    dfence_o   : out std_ulogic;
    i_addr_o   : out std_ulogic_vector(31 downto 0);
    i_stb_o    : out std_ulogic;
    i_meta_o   : out std_ulogic_vector(4 downto 0);
    i_ack_i    : in  std_ulogic;
    i_data_i   : in  std_ulogic_vector(31 downto 0);
    d_addr_o   : out std_ulogic_vector(31 downto 0);
    d_wdata_o  : out std_ulogic_vector(31 downto 0);
    d_ben_o    : out std_ulogic_vector(3 downto 0);
    d_stb_o    : out std_ulogic;
    d_rw_o     : out std_ulogic;
    d_meta_o   : out std_ulogic_vector(4 downto 0);
    d_ack_i    : in  std_ulogic;
    d_data_i   : in  std_ulogic_vector(31 downto 0)
  );
end entity;

architecture rtl of neorv32_cpu_flat is
  signal ibus_req, dbus_req : bus_req_t;
  signal ibus_rsp, dbus_rsp : bus_rsp_t;
begin
  cpu_inst: entity neorv32.neorv32_cpu
  generic map (
    RISCV_ISA_M       => true,
    CPU_FAST_MUL_EN   => true,
    CPU_FAST_SHIFT_EN => true
  )
  port map (
    clk_i      => clk_i,
    rstn_i     => rstn_i,
    mtime_i    => (others => '0'),
    trace_o    => open,
    sleep_o    => sleep_o,
    msi_i      => irq_i(0),
    mei_i      => irq_i(1),
    mti_i      => irq_i(2),
    firq_i     => (others => '0'),
    dbi_i      => '0',
    ifence_o   => ifence_o,
    ibus_req_o => ibus_req,
    ibus_rsp_i => ibus_rsp,
    dfence_o   => dfence_o,
    dbus_req_o => dbus_req,
    dbus_rsp_i => dbus_rsp
  );

  i_addr_o <= ibus_req.addr;
  i_stb_o  <= ibus_req.stb;
  i_meta_o <= ibus_req.meta;
  ibus_rsp.ack  <= i_ack_i;
  ibus_rsp.err  <= '0';
  ibus_rsp.data <= i_data_i;

  d_addr_o  <= dbus_req.addr;
  d_wdata_o <= dbus_req.data;
  d_ben_o   <= dbus_req.ben;
  d_stb_o   <= dbus_req.stb;
  d_rw_o    <= dbus_req.rw;
  d_meta_o  <= dbus_req.meta;
  dbus_rsp.ack  <= d_ack_i;
  dbus_rsp.err  <= '0';
  dbus_rsp.data <= d_data_i;
end architecture;
