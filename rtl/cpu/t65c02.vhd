-- T65 in 65C02 mode with plain ports, for SystemVerilog instantiation (T65's
-- DEBUG record cannot cross the language boundary). One instruction cycle per
-- ce; ce also gates Rdy-independent state, so a stalled bus holds ce low.

library IEEE;
use IEEE.std_logic_1164.all;
use work.T65_Pack.all;

entity t65c02 is
  port(
    clk     : in  std_logic;
    ce      : in  std_logic;
    reset_n : in  std_logic;
    irq_n   : in  std_logic;
    nmi_n   : in  std_logic;
    addr    : out std_logic_vector(15 downto 0);
    din     : in  std_logic_vector(7 downto 0);
    dout    : out std_logic_vector(7 downto 0);
    rw_n    : out std_logic;
    sync    : out std_logic
  );
end t65c02;

architecture rtl of t65c02 is
  signal a24 : std_logic_vector(23 downto 0);
begin
  addr <= a24(15 downto 0);

  u_t65 : entity work.T65
    port map(
      Mode    => "01",
      Res_n   => reset_n,
      Enable  => ce,
      Clk     => clk,
      Rdy     => '1',
      Abort_n => '1',
      IRQ_n   => irq_n,
      NMI_n   => nmi_n,
      SO_n    => '1',
      R_W_n   => rw_n,
      Sync    => sync,
      EF      => open,
      MF      => open,
      XF      => open,
      ML_n    => open,
      VP_n    => open,
      VDA     => open,
      VPA     => open,
      A       => a24,
      DI      => din,
      DO      => dout,
      Regs    => open,
      DEBUG   => open,
      NMI_ack => open
    );
end rtl;
