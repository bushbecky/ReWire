library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

package prims is
  function plusW8 (x : std_logic_vector ; y : std_logic_vector) return std_logic_vector;
end prims;

package body prims is
  function plusW8 (x : std_logic_vector ; y : std_logic_vector) return std_logic_vector
  is
    variable a,b : std_logic_vector(7 downto 0);
    variable c : std_logic_vector(7 downto 0);
  begin
    a := x; b := y;
    c := std_logic_vector(unsigned(a)+unsigned(b));
    return c;
  end plusW8;
end prims;