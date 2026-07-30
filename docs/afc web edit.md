# Landing page

<hero image: https://commons.wikimedia.org/wiki/File:Train_wreck_at_Montparnasse_1895.jpg>

Illegal State in a program is always a problem - that's uncontroversial.

How you defend against this happening is much more contested. Defensive programming, invariants, static analysis, proof assistants. A lot of things have been tried, but Advocates of Strong Types favor this One Weird Trick:

    MAKE ILLEGAL STATES UNREPRESENTABLE

This page will show  what happens as you refine a very basic 'struct' from a "C"-like language with a few tweaks. You bring down the vast space of illegal states until you reach that point where no illegal states can be represented. 

We'll show this by algorithmically generating counter-examples, illegal states, for each representation until we have one that can no longer represent any illegal states. The testing and the structure go hand-in-hand: you don't just trust the structure. But if you have the types and tests right you no longer need, at a minimum, the same level of defensive programming. 

## The Domain

We're going to use as an example a common, real-world, life-or-death situation: train switching systems. 

<insert description of the switching problem here, define all abbreviations and also define our outputs (colour key etc) and illustrate some failure states so that all that is legible in the examples that follow. also explain any simplifications that we're making such as limiting the numbers of strings we consider>

## Naive representation

'''-- v0 state
type State =
  { sa :: String
  , sl :: String
  , se :: String
  , sm :: String
  , p1 :: Boolean
  , p2 :: Boolean
  , t1 :: String
  , t2 :: String
  }
'''

The two obvious problems here are 
1. the String encoding - is it "G", "Green", "green"? what does "" mean? what does "purple" mean"? etc etc
2. Boolean blindness, 'true' here means what? "towards the loop"? 

But what does it mean in practice? Let's use Smallcheck (link) to generate counter examples

<insert most of rung 0 page >

## Commentary on the naive representation

There are a LOT of ways this can go wrong! Many, many states that would result in disaster, derailment and death in the real world if they occurred.

On the next page we'll start refining this.

# Page two: refinements

<we'll leave this as the existing second page for now with one exception, the extinction matrix moves to a new page between this one and the "payoff" where we evaluate the findings. I have a lot of edits to this crucial page but we'll defer them til next phase>

# Page three: evaluation

Extinction matrix goes here as hero image, but we pivot the table so versions are on y-axis and problems are on x-axis

# Page four: the payoff

## Consistency in multi-language environments

Everything you just saw (the oracle, the five types, the enumeration, the counts) is one pure PureScript core with no foreign code in it. The error-repelling surface you watched contract therefore compiles to anything PureScript compiles to.

And that PureScript code can compile and run on at least the following runtimes, integrating with the native languages of those runtimes. 
- Browser/JavaScript
- Node/JavaScript
- Python
- Julia
- BEAM/Erlang
- Go
- Lua
- WASM

### Proving the consistency

<insert existing table and text about how the tests were run and the SHA values and all>