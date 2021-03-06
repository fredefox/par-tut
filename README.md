{-\# OPTIONS\_GHC -pgmL markdown-unlit \#-}

``` {.sourceCode .literate .haskell}
module ParTut ( main ) where

import Control.DeepSeq
import Control.Parallel

import qualified Criterion.Main as Criterion
```

Introduction
============

In this report we will discuss how to do basic parallel programming in
Haskell. We will talk about some of the important aspects that arise
from the special situation of working in a lazy language.

As an example we will show how to implement a parallel map function in
Haskell.

Controlling evaluation
======================

Haskell programmers face a unique challenge when writing parallel
programs. Haskell's laziness makes the order of evaluation
unpredictable. To get the optimal performance out of a parallel Haskell
program, the programmer must take care to explicitly control the order
of evaluation. Let's say you want to compute two expressions `a` and `b`
in parallel and suppose that both expressions depend on the result of
some common expression `e`, then naïvely starting a computation of `a`
in parallel with `b` could lead to extra work being performed. Similarly
`b` might depend on `a` in which case the evaluation of `b` won't be
able to finish until `a` is available. This will also result in more
work being performed.

Controlling evaluation with `seq`
---------------------------------

The two previous examples illustrate the need for a way of controlling
1) forcing evaluations and 2) controlling evaluation order. Partially
evaluated expressions are represented as *thunks* in Haskell. These can
be thought of as a description of how to arrive at a final result.
Thunks can be inspected in `ghci` using `:sprint`. A simple example will
show this:

``` {.sourceCode .haskell}
§ let x = "Hi there."
§ :sprint x
> x = _
```

The `_`-part here is the unevaluated part of the expression. We see that
nothing is evaluated immediately after the definition of `x`. We can
force a value to be evaluated to *Weak Head Normal Form* (WHNF for
short) by using `seq`:

``` {.sourceCode .haskell}
§ seq x ()
§ :sprint x
> x = 'H' : _
```

Now we see that part of `x` is evaluted. Note, however, that the
reduction of `x` to WHNF will only happen once the result of `seq x ()`
is needed. So in this example `x` is not reduced:

``` {.sourceCode .haskell}
§ let x = "Ahoy!"
§ let _ = x `seq` () in ()
§ :sprint x
> x = _
```

A word of warning: `ghc` may throw you off track if you try this
yourself. For instance in this example:

``` {.sourceCode .haskell}
§ let x = 2
§ seq x ()
§ :sprint x
> x = _
```

`x` is still not in WHNF! What is going on? Looking closer at the type
of `x` we see that it has the type:

``` {.sourceCode .haskell}
§ :t x
> x :: Num  => t
```

Think of the constraints as regular function parameters (which in a
sense is exactly what they are). The type of `x` is polymorphic due to
how Haskell treats the piece of syntax that is a number - it's
essentially syntactic sugar for `fromInteger x`. So really `x` is in
WHNF, but it's a lambda-abstraction! Here is another interesting example
of a function behaving unexpectedly:

``` {.sourceCode .haskell}
§ s <- readFile "/dev/zero"
§ :sprint s
> s = _
§ seq s ()
> ()
§ :sprint s
> s = '' : '' : '' : ... : _
```

We see that when we first try to `sprint` `s` that no reading has
actually taken place. When we force it to WHNF it suddenly contains not
only the first element of the list, but a decent chunk of
null-characters.

`seq` does not give guarantees as to which operand will be evaluated
first. For that reason it has a close cousin named `pseq` defined in the
package `parallel` which behaves identically to `seq` with this extra
guarantee.

Full evaluation using `NFData`
------------------------------

As mentioned above we wanted to be able to control forcing evaluation
and evaluation order. We get this from `pseq`, but evaluating something
to WHNF cannot always be a sufficiently large task for it to be
worthwhile doing in parallel. This is because there is an overhead
associated with starting parallel computations in Haskell. For that
reason we want to be able to explicitly fully evaluate expressions. The
`deepseq` package defines a typeclass `NFData` that lets us do exactly
that:

``` {.sourceCode .haskell}
class NFData a where
  rnf :: a -> ()
```

And it works as expected:

``` {.sourceCode .haskell}
§ let x = "Tjena!"
§ rnf x
§ :sprint x
> x = "Tjena!"
```

Instances of `NFData` can then be given for various types that give
description of how to fully evaluate members of it's type. E.g.:

``` {.sourceCode .haskell}
instance NFData a => NFData [a] where
  rnf [] = ()
  rnf (a : as) = rnf a `seq` rnf as
```

Parallel evaluation
===================

If we want to evaluate two expressions in parallel we need to explicitly
state this in our program. If we have two expressions `a` and `b` that
we wist to evaluate in parallel, then we can inform GHC like so:

``` {.sourceCode .haskell}
a `par` b
```

Now, GHC can be a bit fickle - this may not actually result in `a` and
`b` being evaluated in parallel. What it will do, however, is create a
*spark*. A spark can be thought of as a potential source of parallelism.
One advantage of sparks is that they are really cheap to create. So when
parallelizing programs in Haskell we can be generous with creating them.
However, we still want our sparks to do a reasonable amount of work so
that the parallelism outweighs the overhead of using sparks.

Parmap
======

To illustrate some of the challenges that face the parallel Haskell
programmer we will now implement a parallel map function. All benchmark
results given are times measured with Criterion. A full bench-suite and
results are given at the end.

For testing purposes we define a function `nfib` which serves as a
convenient way of making a bunch of busy-work for your machine.

``` {.sourceCode .literate .haskell}
nfib :: Int -> Integer
nfib n
  | n <= 0 = 0
  | otherwise = nfib ( n - 1 ) + nfib ( n - 2 ) + 1
```

Our reference benchmark will be task \#0:

``` {.sourceCode .literate .haskell}
task0 :: Int -> [Integer]
task0 m = map nfib [0..m]
```

Which took 811.1 ms to compute.

Our first try at a parallel map is `parMap0`:

``` {.sourceCode .literate .haskell}
parMap0 :: (a -> b) -> [a] -> [b]
parMap0 _ [] = []
parMap0 f (x : xs) = fx `par` fx : parMap0 f xs
  where
    fx = f x
```

This implementation gives rise to task \#1:

``` {.sourceCode .literate .haskell}
task1 :: Int -> [Integer]
task1 m = parMap0 nfib [0..m]
```

It took 861.4 ms to run. One problem with this implementation is that it
will correctly spark the application of `f` on the first argument, but
that value is used immediately afterwards in the call to `(:)` so in
reality we're not gaining any parallelism, but suffering the overhead of
creating sparks as can be seen from the benchmark output.

We fix this in our next attempt; what we really want to do is create a
spark for the application of `f` to `x` *as well as* a spark for the
rest of the computation (i.e. the recursive call):

``` {.sourceCode .literate .haskell}
parMap1 :: (a -> b) -> [a] -> [b]
parMap1 _ []       = []
parMap1 f (x : xs) = fx `par` fxs `pseq` fx : fxs
  where
    fx  = f x
    fxs = parMap1 f xs
```

What this does, essentially, is to create a spark for each individual
application of `f` all along the "spine" of the list". And once the very
last application is reduced to WHNF (due to the call to `pseq`) we will
start "zipping" the list back together (the calls to `(:)`).

And so we have task \#2:

``` {.sourceCode .literate .haskell}
task2 :: Int -> [Integer]
task2 m = parMap1 nfib [0..m]
```

Which runs at 491.9 ms. A great improvement! But there's still an issue;
`f x` is only reduced to WHNF! This was not a problem in our previous
computation because the weak head normal form was actually the same as
the normal form. But what if we called some devious function:

``` {.sourceCode .literate .haskell}
devious :: Int -> [Integer]
devious n = [0, nfib n]
```

Where the real work-load is burried deeper into the structure that we're
computing, what will happen then? Let's find out:

``` {.sourceCode .literate .haskell}
task3 :: Int -> [[Integer]]
task3 m = parMap1 devious [0..m]
```

This task runs at 964.6 ms. Uh-oh! We're right back where we started.
What can we do about this? Well, we can just force *the whole*
computation of course. Enter `force`:

``` {.sourceCode .literate .haskell}
parMap2 :: NFData b => (a -> b) -> [a] -> [b]
parMap2 _ []       = []
parMap2 f (x : xs) = fx `par` fxs `pseq` fx : fxs
  where
    fx  = force $ f x
    fxs = force $ parMap2 f xs
```

This gives rise to task \#4:

``` {.sourceCode .literate .haskell}
task4 :: Int -> [[Integer]]
task4 m = parMap2 devious [0..m]
```

Which runs at 428.5 ms. Phew! We're back to getting a decent speedup
again. May the force be with you.

As a last remark we want to illustrate that there can be cases where the
task the programmer is mapping is too small for comfort. In this, our
5th task, we're calling `nfib 5` a given number of times. On my machine
`nfib 5` takes approx. 0.05 s.

``` {.sourceCode .literate .haskell}
task5 :: Int -> [Integer]
task5 m = parMap2 nfib $ replicate m 5
```

This task takes 325.8 ms. Can we do better? Well, to do better we have
to modify our `parMap` slightly. We need a way to control granularity.
We can do that like so:

``` {.sourceCode .literate .haskell}
parMapChunked :: NFData b => Int -> (a -> b) -> [a] -> [b]
parMapChunked sz f xs = concat $ parMap2 (map f) $ chunksOf sz xs
  where
    chunksOf :: Int -> [a] -> [[a]]
    chunksOf _ [] = []
    chunksOf n xs' = l : chunksOf n r
      where
        (l, r) = splitAt n xs'
```

The parallel map now takes an extra argument. It first divides the
input-list into a list of lists with size `sz` and then calculates `f`
applied to each of the elements of these sublists in a sequential
manner. That way, `sz` should act as a sort of scaling factor for the
problem size. Unfortunately the ideal size will vary from machine to
machine and from input to input. Only testing can give you an idea of
what the ideal size is.

We can try running 10 "`f`'s" sequentially in each spark:

``` {.sourceCode .literate .haskell}
granularity :: Int
granularity = 10
```

``` {.sourceCode .literate .haskell}
parMap3 :: NFData b => (a -> b) -> [a] -> [b]
parMap3 = parMapChunked granularity
```

``` {.sourceCode .literate .haskell}
task6 :: Int -> [Integer]
task6 m = parMap3 nfib $ replicate m 5
```

Ths takes us down to 54.49 ms so indeed there was a speed-up to gain
from doing that.

Appendix: Benchmark results
===========================

``` {.sourceCode .literate .haskell}
main :: IO ()
main = benchmark
```

``` {.sourceCode .literate .haskell}
benchmark :: IO ()
benchmark =
  Criterion.defaultMain
    [ "[sequential map]"              >:> task0
    , "[broken parallel map]"         >:> task1
    , "[parallel map]"                >:> task2
    , "[parallel map + devious]"      >:> task3
    , "[parallel map + force]"        >:> task4
    , "[parallel map + small tasks]"  >::> task5
    , "[parallel map + control size]" >::> task6
    ]
  where
    s >:> f = Criterion.bench s (Criterion.nf f 30)
    s >::> f = Criterion.bench s (Criterion.nf f 8000)
```

    benchmarking [sequential map]
    time                 754.2 ms   (222.2 ms .. 1.798 s)
                         0.818 R²   (0.722 R² .. 1.000 R²)
    mean                 1.048 s    (831.8 ms .. 1.218 s)
    std dev              264.4 ms   (0.0 s .. 295.0 ms)
    variance introduced by outliers: 48% (moderately inflated)

    benchmarking [broken parallel map]
    time                 861.4 ms   (607.2 ms .. 1.038 s)
                         0.987 R²   (0.980 R² .. 1.000 R²)
    mean                 943.4 ms   (876.0 ms .. 980.9 ms)
    std dev              59.50 ms   (0.0 s .. 65.03 ms)
    variance introduced by outliers: 19% (moderately inflated)

    benchmarking [parallel map]
    time                 491.9 ms   (453.0 ms .. 539.6 ms)
                         0.999 R²   (0.996 R² .. 1.000 R²)
    mean                 492.5 ms   (486.2 ms .. 498.0 ms)
    std dev              8.941 ms   (0.0 s .. 9.574 ms)
    variance introduced by outliers: 19% (moderately inflated)

    benchmarking [parallel map + devious]
    time                 964.6 ms   (NaN s .. 1.139 s)
                         0.996 R²   (0.989 R² .. 1.000 R²)
    mean                 911.8 ms   (857.9 ms .. 943.0 ms)
    std dev              48.43 ms   (0.0 s .. 54.17 ms)
    variance introduced by outliers: 19% (moderately inflated)

    benchmarking [parallel map + force]
    time                 428.5 ms   (415.5 ms .. 438.5 ms)
                         1.000 R²   (1.000 R² .. 1.000 R²)
    mean                 432.1 ms   (429.6 ms .. 433.6 ms)
    std dev              2.360 ms   (0.0 s .. 2.719 ms)
    variance introduced by outliers: 19% (moderately inflated)

    benchmarking [parallel map + small tasks]
    time                 325.8 ms   (314.2 ms .. 338.8 ms)
                         1.000 R²   (0.999 R² .. 1.000 R²)
    mean                 320.4 ms   (316.7 ms .. 323.2 ms)
    std dev              4.533 ms   (1.928 ms .. 5.628 ms)
    variance introduced by outliers: 16% (moderately inflated)

    benchmarking [parallel map + control size]
    time                 54.49 ms   (51.37 ms .. 56.98 ms)
                         0.995 R²   (0.989 R² .. 0.999 R²)
    mean                 54.33 ms   (53.10 ms .. 55.65 ms)
    std dev              2.302 ms   (1.717 ms .. 3.109 ms)
