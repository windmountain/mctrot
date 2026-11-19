module Simplify exposing (Ranked, atLevel, keptCount, rank, totalCount)

{-| Visvalingam–Whyatt simplification of an SVG outline (M, L and Z only,
as in LiveMapData.boroughPath), for choosing how simple Manhattan's
outline on /live should be.

Each point gets an "effective area": the area of the triangle it makes
with its neighbours at the moment it would be removed, if points were
removed smallest first (made never to decrease, so removing in that order
is consistent). That's worked out once, by `rank`; any simplification
after that only keeps the points whose area is at least some threshold,
which is cheap enough to redo on every move of a slider.

-}

import Array exposing (Array)



-- RANKED


type Ranked
    = Ranked
        { rings : List (List ( Float, Float, Float ))
        , areas : Array Float -- every point's area, largest first
        }


{-| Work out every point's effective area. Each ring's first and last
points are always kept.
-}
rank : String -> Ranked
rank d =
    let
        rings =
            parse d |> List.map effectiveAreas
    in
    Ranked
        { rings = rings
        , areas =
            rings
                |> List.concatMap (List.map (\( _, _, a ) -> a))
                |> List.sort
                |> List.reverse
                |> Array.fromList
        }


totalCount : Ranked -> Int
totalCount (Ranked r) =
    Array.length r.areas


{-| How many points are kept at a level from 0 (all of them) to 100 (a
handful): evenly spaced on a log scale, so each step of the slider drops a
similar share of what's left.
-}
keptCount : Float -> Ranked -> Int
keptCount level (Ranked r) =
    let
        total =
            toFloat (Array.length r.areas)

        fewest =
            min total 12
    in
    if total <= 0 then
        0

    else
        round (total * ((fewest / total) ^ (clamp 0 100 level / 100)))


{-| The outline at a level from 0 to 100, as an SVG path, and the smallest
effective area kept (in the map's square units).
-}
atLevel : Float -> Ranked -> { d : String, threshold : Float }
atLevel level ((Ranked r) as ranked) =
    let
        threshold =
            Array.get (keptCount level ranked - 1) r.areas |> Maybe.withDefault 0
    in
    { d =
        r.rings
            |> List.map (List.filter (\( _, _, a ) -> a >= threshold))
            |> List.filter (\ring -> List.length ring >= 3)
            |> List.map ringPath
            |> String.join " "
    , threshold = threshold
    }


ringPath : List ( Float, Float, Float ) -> String
ringPath ring =
    case ring of
        ( x, y, _ ) :: rest ->
            "M "
                ++ coord x
                ++ " "
                ++ coord y
                ++ " L "
                ++ String.join " " (List.map (\( px, py, _ ) -> coord px ++ " " ++ coord py) rest)
                ++ " Z"

        [] ->
            ""


coord : Float -> String
coord f =
    String.fromFloat (toFloat (round (f * 10)) / 10)



-- PARSING


{-| The rings of a path made of M, L and Z.
-}
parse : String -> List (List ( Float, Float ))
parse d =
    let
        step word ( rings, current, pending ) =
            case word of
                "M" ->
                    ( close current rings, [], Nothing )

                "L" ->
                    ( rings, current, pending )

                "Z" ->
                    ( close current rings, [], Nothing )

                _ ->
                    case ( String.toFloat word, pending ) of
                        ( Just y, Just x ) ->
                            ( rings, ( x, y ) :: current, Nothing )

                        ( Just x, Nothing ) ->
                            ( rings, current, Just x )

                        ( Nothing, _ ) ->
                            ( rings, current, pending )

        close current rings =
            if List.isEmpty current then
                rings

            else
                List.reverse current :: rings

        ( done, last, _ ) =
            List.foldl step ( [], [], Nothing ) (String.words d)
    in
    List.reverse (close last done)



-- VISVALINGAM–WHYATT


{-| Each point with its effective area; the ends get infinity.
-}
effectiveAreas : List ( Float, Float ) -> List ( Float, Float, Float )
effectiveAreas ring =
    let
        points =
            Array.fromList ring

        n =
            Array.length points

        at i =
            Array.get i points |> Maybe.withDefault ( 0, 0 )

        triangle i j k =
            let
                ( ax, ay ) =
                    at i

                ( bx, by ) =
                    at j

                ( cx, cy ) =
                    at k
            in
            abs ((bx - ax) * (cy - ay) - (cx - ax) * (by - ay)) / 2

        start =
            { prev = Array.initialize n (\i -> i - 1)
            , next = Array.initialize n (\i -> i + 1)
            , current = Array.initialize n (\i -> if i == 0 || i == n - 1 then infinity else triangle (i - 1) i (i + 1))
            , result = Array.repeat n infinity
            , heap =
                List.range 1 (n - 2)
                    |> List.foldl (\i h -> insert ( triangle (i - 1) i (i + 1), i ) h) Empty
            , largest = 0
            }

        -- Remove the smallest point, then re-measure its neighbours.
        loop s =
            case pop s.heap of
                Nothing ->
                    s.result

                Just ( ( area, i ), heap ) ->
                    if Array.get i s.current /= Just area then
                        -- Stale: removed already, or re-measured since.
                        loop { s | heap = heap }

                    else
                        let
                            p =
                                Array.get i s.prev |> Maybe.withDefault -1

                            q =
                                Array.get i s.next |> Maybe.withDefault n

                            effective =
                                max area s.largest

                            prev =
                                Array.set q p s.prev

                            next =
                                Array.set p q s.next

                            remeasure j ( current, h ) =
                                if j <= 0 || j >= n - 1 then
                                    ( current, h )

                                else
                                    let
                                        a =
                                            triangle (Array.get j prev |> Maybe.withDefault 0) j (Array.get j next |> Maybe.withDefault 0)
                                    in
                                    ( Array.set j a current, insert ( a, j ) h )

                            ( current2, heap2 ) =
                                ( Array.set i nan s.current, heap )
                                    |> remeasure p
                                    |> remeasure q
                        in
                        loop
                            { s
                                | prev = prev
                                , next = next
                                , current = current2
                                , heap = heap2
                                , result = Array.set i effective s.result
                                , largest = effective
                            }
    in
    if n < 3 then
        List.map (\( x, y ) -> ( x, y, infinity )) ring

    else
        List.map2 (\( x, y ) a -> ( x, y, a )) ring (Array.toList (loop start))


infinity : Float
infinity =
    1 / 0


nan : Float
nan =
    0 / 0



-- A PAIRING HEAP, smallest area first


type Heap
    = Empty
    | Node ( Float, Int ) (List Heap)


insert : ( Float, Int ) -> Heap -> Heap
insert x h =
    merge (Node x []) h


merge : Heap -> Heap -> Heap
merge a b =
    case ( a, b ) of
        ( Empty, _ ) ->
            b

        ( _, Empty ) ->
            a

        ( Node x xs, Node y ys ) ->
            if Tuple.first x <= Tuple.first y then
                Node x (b :: xs)

            else
                Node y (a :: ys)


pop : Heap -> Maybe ( ( Float, Int ), Heap )
pop h =
    case h of
        Empty ->
            Nothing

        Node x children ->
            Just ( x, mergePairs children )


{-| The usual two passes (pairs left to right, then merged right to left),
without deep recursion: the root can have thousands of children.
-}
mergePairs : List Heap -> Heap
mergePairs hs =
    let
        pairs acc rest =
            case rest of
                a :: b :: more ->
                    pairs (merge a b :: acc) more

                [ a ] ->
                    a :: acc

                [] ->
                    acc
    in
    List.foldl merge Empty (pairs [] hs)
