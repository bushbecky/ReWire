# ReWire

[![Build Status](https://travis-ci.org/mu-chaco/ReWire.svg)](https://travis-ci.org/mu-chaco/ReWire)

ReWire is an experimental compiler for a subset of [Haskell](http://haskell.org/) to VHDL, suitable for synthesis and implementation on FPGAs. ReWire enables a semantics-directed style of synchronous hardware development, based on reactive resumption monads.

## Simple Example: Fibonacci Sequence

The example program produces the elements of the Fibonacci sequence on its output (encoded as 8-bit integers, so things will overflow pretty quickly!). The circuit has a one-bit input that pauses the circuit's operation on low. Our example consists of two parts: **Fibonacci.rw** is the ReWire code, and **prims.vhd** contains a few supporting functions written in VHDL.

### Fibonacci.rw
```haskell
--
-- The compiler doesn't yet support a "prelude" so we will have to define a
-- few things ourselves!
--
data Bit        = Zero | One
data W8         = W8 Bit Bit Bit Bit Bit Bit Bit Bit
data Unit       = Unit
data Tuple2 a b = Tuple2 a b

plusW8 :: W8 -> W8 -> W8
plusW8 x y = nativeVhdl "plusW8" plusW8 x y

zeroW8 :: W8
zeroW8 = W8 Zero Zero Zero Zero Zero Zero Zero Zero

oneW8 :: W8
oneW8 = W8 Zero Zero Zero Zero Zero Zero Zero One

--
-- End stuff that will eventually be in the prelude.
--

start :: ReT Bit W8 I ()
start = begin

begin :: ReT Bit W8 I ()
begin = loop zeroW8 oneW8

loop :: W8 -> W8 -> ReT Bit W8 I ()
loop n m = do b <- signal n
              case b of
                  One  -> loop n m
                  Zero -> loop m (plusW8 n m)
```

### prims.vhd
```vhdl
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package prims is
  pure function plusW8 (x : std_logic_vector; y : std_logic_vector) return std_logic_vector;
end prims;

package body prims is
  pure function plusW8 (x : std_logic_vector; y : std_logic_vector) return std_logic_vector is
  begin
	return (std_logic_vector(unsigned(x)+unsigned(y)));
  end plusW8;
end prims;
```

## Installation

### Requirements

ReWire is developed against the latest version of the [Haskell Platform](https://www.haskell.org/platform/). The generated VHDL has only been tested with the Xilinx ISE toolchain, but since it makes no use (yet) of Xilinx-specific primitives it should be reasonably portable to other VHDL implementations.

### Building

```
$ git clone git@github.com:mu-chaco/ReWire.git
$ cd ReWire
$ cabal configure
$ cabal install
```

## Usage

The main executable file for the compiler is **rwc** (short for ReWire Compiler).

### Compiling to VHDL

```
$ cd ReWire/examples/Fibonacci
$ rwc Fibonacci.hs -o Fibonacci.vhd
```

We should now have two VHDL files: **Fibonacci.vhd** (generated by rwc) is the main VHDL module for our program, and **prims.vhd** (pre-supplied) contains VHDL-defined primitives.

### Synthesis/Implementation

1. Create a new Xilinx ISE project.
2. Add Fibonacci.vhd and prims.vhd to the project.
3. Simulate/synthesize/implement as you normally would.

For the Fibonacci example, the top-level VHDL entity will have inputs and outputs as follows:

```vhdl
entity rewire is
  Port ( clk : in std_logic ;
         input : in std_logic_vector (0 to 0);
         output : out std_logic_vector (0 to 7));
end rewire;
```

The one-bit input and the eight-bit output on the VHDL side correspond respectively to the Bit-typed input and the W8-typed output on the ReWire side.

## Caveats

### Concrete Syntax
For the moment, the concrete syntax supported by ReWire is a bit different from Haskell in certain places. Specifically:

1. All function definitions must be made at the top level, must be accompanied with a type signature:
```haskell
f :: W8 -> W8
f x = plusW8 x x
```

### Polymorphism and Recursion

Polymorphic and higher-order functions are not allowed at runtime, though some undocumented maneuvers at the interactive prompt allow them to be used in certain situations.

Recursive functions must be guarded and typed in a reactive resumption monad (see the papers below for more details)

### Termination

At the moment we are not able to correctly synthesize circuits whose execution terminates (i.e. ends with a *return* statement), so make sure the *start* loop is infinite.

### VHDL Generation

Generated VHDL, when synthesized, may throw a lot of warnings about unused variables. This is normal, and does not seem to have an effect on the synthesized circuits.

## Further Reading

1. Adam Procter, William L. Harrison, Ian Graves, Michela Becchi, and Gerard Allwein. Semantics Driven Hardware Design, Implementation, and Verification with ReWire. In *Proceedings of the 16th ACM SIGPLAN/SIGBED Conference on Languages, Compilers and Tools for Embedded Systems (LCTES'15)*. ACM, New York, NY, USA, 10 pages. http://doi.acm.org/10.1145/2670529.2754970
2. Ian Graves, Adam Procter, William L. Harrison, and Gerard Allwein. Provably Correct Development of Reconfigurable Hardware Designs via Equational Reasoning. To appear at the 2015 International Conference on Field-Programmable Technology.
3. Adam Procter, William L. Harrison, Ian Graves, Michela Becchi, and Gerard Allwein. Semantics-Directed Machine Architecture in ReWire. In *2013 International Conference on Field-Programmable Technology*.
