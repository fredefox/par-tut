{-# OPTIONS_GHC -pgmL markdown-unlit #-}

> module ParTut ( main ) where
>
> import Control.DeepSeq
> import Control.Parallel
>
> import qualified Criterion.Main as Criterion

Introduction
============

In this report we will discuss how to do basic parallel programming in haskell.
We will talk about some of the import aspects that arise from the special
situation of working in a lazy language.

Then we will show how to implement a parallel map function in haskell.

Controlling evaluation
======================

When writing parallel programs in Haskell there is one particular thing that the
author most pay particaluar attention to, namely controlling the order of
evaluation. Since haskell is lazy by default extra care needs to be put into the
construction of parallel programs. Say you want to compute two expressions `a`
and `b` in parallel and suppose that both expressions depend on the result of
some common expression `e` (`e` appears free in `a` and `b`), then naïvely
starting a computation of `a` in parallel with `b` would lead to extra work
being performed. Similarly `b` might result depend on `a` in which case the
evaluation of `b` won't be able to finish until `a` is available. This will also
to "too much" work being performed.

Controlling evaluation with `seq`
---------------------------------

These two examples clearly motivate the need for a way of controlling 1) forcing
evaluations and 2) controlling evaluation order. Partially evaluated expressions
are represented as "thunks" in haskell. These can be thought of as a description
on how to arrive at a final result. Thunks can be inspected in `ghci` using
`:sprint`. A simple example will show this:

< § let x = "Hi there."
< § :sprint x
< > x = _

The `_` -part here is the unevaluated part of the expression. We see that
nothing is evaluated immediately after the definition of `x`. We can force a
value to be evaluated to *Weak Head Normal Form* or WHNF for short by using
`seq`:

< § seq x ()
< § :sprint x
< > x = 'H' : _

Now we see that part of `x` is evaluted. Note, however, that the reduction of
`x` to WHNF will only happen once the result of the entire expression is needed.
So in this example `x` is not reduced:

< § let x = "Ahoy!"
< § let _ = x `seq` () in ()
< § :sprint x
< > x = _

A word of warning: `ghc` may throw you off track if you try this yourself. For
instance in this example:

< § let x = 2
< § seq x ()
< § :sprint x
< > x = _

`x` is still not in WHNF! What is going on? Looking closer at the type of `x` we
see that it has the type:

< § :t x
< > x :: Num t => t

Think of the constraints as regular function parameters (which in a sense is
exactly what they are). The type of `x` is polymorphic due to how haskell treats
the piece of syntax that is a number - it's essentially syntactic sugar for
`fromInteger x`. So `x` cannot be evaluated to WHNF because it is not fully
applied! Haskell non-zealous commitment pops up all sorts of unexpected places.
Take this for example:

< § s <- readFile "/dev/zero"
< § :sprint s
< > s = _
< § seq s ()
< > ()
< § :sprint s
< > s = '' : '' : '' : ... : _

We see that when we first try to `sprint` `s` no reading has actually taken
place. When we force it to WHNF it suddenly contains, not only it's first
argument but a decent chunk of null-characters.

`seq` does not give guarantees as to which operand will be evaluated first. For
that reason it has a close cousin named `pseq` defined in the package `parallel`
which behaves identically to `seq` with this extra guarantee.

Full evaluation using `NFData`
------------------------------

As mentioned above we wanted to be able to control forcing evaluation and
evaluation order. We get this from `pseq`, but surely evaluating something to
WHNF cannot always be sufficiently large task for it to be something worthwhile
doing in parallel. This is exactly right. What if we want to fully evaluate an
expression? Well for that we utilize haskells typeclass system.

The `deepseq` package defines a typeclass `NFData` that lets us do exactly that:

< class NFData a where
<   rnf :: a -> ()

And it works as expected:

< § let x = "Tjena!"
< § rnf x
< § :sprint x
< > x = "Tjena!"

Parallel evaluation
===================

If we want to evaluate two expressions in parallel we need to explicitly state
this in our program. If we have to expressions `a` and `b` that don't depend on
each other we inform ghc of our wish like so:

< a `par` b

Now, ghc can be a bit fickle - this may not actually result in `a` and `b` being
evaluated in parallel. What it will do, however, is create a *spark*. A spark
can be thought of as a potential source of parallelism. One advantage of sparks
is that they are really cheap to create. So when parallelizing programs in
haskell we can be generous with creating them. However, we still want our sparks
to do a reasonable amount of work so that the parallelism outways the overhead
of using sparks.

Parmap
======

To illustrate some of the challenges that faces the parallel haskell programmer
we will now implement a parallel map function. All benchmark results mentioned
are times measured with Criterion. Full bench-suite and results are given at the
end.

For testing purposes we define a function `nfib` which serves as a convenient
way of generating a bunch of instructions for your machine:

> nfib :: Int -> Integer
> nfib n
>   | n <= 0 = 0
>   | otherwise = nfib ( n - 1 ) + nfib ( n - 2 ) + 1

Our reference benchmark will be task #0:

> task0 :: Int -> [Integer]
> task0 m = map nfib [0..m]

Which took 811.1 ms to compute.

Our first try at a parallel map is `parMap0`:

> parMap0 :: (a -> b) -> [a] -> [b]
> parMap0 _ [] = []
> parMap0 f (x : xs) = fx `par` fx : parMap0 f xs
>   where
>     fx = f x

This implementation gives rise to task #1:

> task1 :: Int -> [Integer]
> task1 m = parMap0 nfib [0..m]

It took 861.4 ms to run. One problem with this implementation is that it will
correctly spark the application of f on the first argument, but that value is
used immediately afterwards in the call to `(:)` so in reality we're gaining not
parallelism, but suffering the overhead of creating sparks as can be seen from
the benchmark output.

We fix this in our next implemenation. What we really want to do is create a
spark for the application of `f` to `x` *as well* as a spark for the rest of the
computation (i.e. the recursive call):

> parMap1 :: (a -> b) -> [a] -> [b]
> parMap1 _ []       = []
> parMap1 f (x : xs) = fx `par` fxs `pseq` fx : fxs
>   where
>     fx  = f x
>     fxs = parMap1 f xs

What this does, essentially, is to create a spark for each individual
application of `f` all along the "spine" of the list". And once the very last
application is reduced to WHNF (due to the call to `pseq`) we will start
"zipping" the list back together (the calls to `(:)`).

And so we have task #2:

> task2 :: Int -> [Integer]
> task2 m = parMap1 nfib [0..m]

Which runs at 491.9 ms. A great improvement. But there's still an issue. The
issue is that `f x` is only reduced to WHNF. This was not a problem in our
previous computation because the weak head normal form was actually the same as
the normal form. But what if we called some devious function:

> devious :: Int -> [Integer]
> devious n = [0, nfib n]

Where the real work-load is burried deeper into the structure that we're
computing, what will happen then? Let's find out:

> task3 :: Int -> [[Integer]]
> task3 m = parMap1 devious [0..m]

This task runs at 964.6 ms. Uh-oh! We're right back where we started. What can
we do about this? Well, we can just force *the whole* computation of course.
Enter `force`:

> parMap2 :: NFData b => (a -> b) -> [a] -> [b]
> parMap2 _ []       = []
> parMap2 f (x : xs) = fx `par` fxs `pseq` fx : fxs
>   where
>     fx  = force $ f x
>     fxs = force $ parMap2 f xs

This gives rise to task #4:

> task4 :: Int -> [[Integer]]
> task4 m = parMap2 devious [0..m]

Which runs at 428.5 ms. Phew! We're back to getting a decent speedup again. May
the force be with you.

As a last remark I want to illustrate that there can be cases where the task
you're mapping is too small for comfort. In this, our 5th task, we're calling
`nfib 5` a given number of times. On my machine `nfib 5` takes approx. 0.05 s.

> task5 :: Int -> [Integer]
> task5 m = parMap2 nfib $ replicate m 5

This task takes 325.8 ms. Can we do better? Well, to do better we have to modify
our `parMap` slightly. We need a way to control granularity. We do that like this:

> parMapChunked :: NFData b => Int -> (a -> b) -> [a] -> [b]
> parMapChunked sz f xs = concat $ parMap2 (map f) $ chunksOf sz xs
>   where
>     chunksOf :: Int -> [a] -> [[a]]
>     chunksOf _ [] = []
>     chunksOf n xs' = l : chunksOf n r
>       where
>         (l, r) = splitAt n xs'

The parallel map now takes an extra argument. It first divides the input-list
into a list of lists with size `sz` and then calculates `f` applied to each of
the elements of these sublists in a sequential manner. That way, `sz` should act
as a sort of scaling factor for the problem size. Unfortunately the ideal size
will vary from machine to machine and from input to input. Only testing can give
you an idea of what the ideal size is.

We can try running 10 "`f`'s" sequentially in each spark:

> granularity :: Int
> granularity = 10

> parMap3 :: NFData b => (a -> b) -> [a] -> [b]
> parMap3 = parMapChunked granularity

> task6 :: Int -> [Integer]
> task6 m = parMap3 nfib $ replicate m 5

Ths takes us down to 54.49 ms so indeed there was a speed-up to gain from doing that.

Appendix: Benchmark results
===========================

> main :: IO ()
> main = benchmark

> benchmark :: IO ()
> benchmark =
>   Criterion.defaultMain
>     [ "[sequential map]"              >:> task0
>     , "[broken parallel map]"         >:> task1
>     , "[parallel map]"                >:> task2
>     , "[parallel map + devious]"      >:> task3
>     , "[parallel map + force]"        >:> task4
>     , "[parallel map + small tasks]"  >::> task5
>     , "[parallel map + control size]" >::> task6
>     ]
>   where
>     s >:> f = Criterion.bench s (Criterion.nf f 30)
>     s >::> f = Criterion.bench s (Criterion.nf f 8000)

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
