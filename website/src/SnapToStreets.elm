module SnapToStreets exposing (Network, fromPath, snap)

{-| The path walked, redrawn along the streets: for /live's map, so GPS
wobble doesn't show and corners come out square.

Each GPS fix is moved onto the nearest street in the network (the streets
between McDonald's, LiveMapData.networkPath) if one's within `maxSnap`;
between one fix and the next, the line follows the streets the shortest
way, unless that's so much longer than the gap between them
(`maxDetour`) that the streets can't explain it (a subway ride, a street
not in the network), when it's drawn straight. A fix with no street near
stays where it is.

Everything is in the map's coordinates (src/Projection.elm): feet.

-}

import Array exposing (Array)
import Dict exposing (Dict)


{-| A straight bit of street: from one corner of the network to the next.
-}
type alias Segment =
    { a : Node
    , b : Node
    }


{-| A corner of the network: where its streets bend or meet, in whole feet
(the network's corners land on whole feet, and streets meeting share one).
-}
type alias Node =
    ( Int, Int )


type Network
    = Network
        { segments : Array Segment
        , cells : Dict ( Int, Int ) (List Int)
        , neighbours : Dict Node (List ( Node, Float ))
        }


{-| How far a fix can be from a street and still be moved onto it: about
60 m.
-}
maxSnap : Float
maxSnap =
    200


{-| The longest way along the streets between two fixes, against the
straight line between them, before it's drawn straight instead: so far,
plus this many feet (for going round a block).
-}
maxDetour : { times : Float, plus : Float }
maxDetour =
    { times = 2.5, plus = 400 }


{-| The grid that finds streets near a point: squares this many feet
across, each listing the segments that cross it. At least `maxSnap`, so a
point's own square and the eight around it hold every street near enough.
-}
cellSize : Float
cellSize =
    400


{-| The network from an SVG path of `M x y l dx dy ...` (and `L x y`)
moves, as LiveMapData.networkPath has it.
-}
fromPath : String -> Network
fromPath path =
    let
        segments =
            Array.fromList (parse (String.words path))

        cellsOf seg =
            let
                ( ax, ay ) =
                    toFloats seg.a

                ( bx, by ) =
                    toFloats seg.b
            in
            List.range (cell (min ax bx)) (cell (max ax bx))
                |> List.concatMap (\cx -> List.range (cell (min ay by)) (cell (max ay by)) |> List.map (\cy -> ( cx, cy )))

        cells =
            Array.foldl
                (\seg ( i, acc ) ->
                    ( i + 1
                    , List.foldl (\key -> Dict.update key (\list -> Just (i :: Maybe.withDefault [] list))) acc (cellsOf seg)
                    )
                )
                ( 0, Dict.empty )
                segments
                |> Tuple.second

        link from to =
            Dict.update from (\list -> Just (( to, distance (toFloats from) (toFloats to) ) :: Maybe.withDefault [] list))

        neighbours =
            Array.foldl (\seg -> link seg.a seg.b >> link seg.b seg.a) Dict.empty segments
    in
    Network { segments = segments, cells = cells, neighbours = neighbours }


{-| The path's segments: each move after the first in a subpath draws one.
-}
parse : List String -> List Segment
parse tokens =
    let
        go remaining command at acc =
            case remaining of
                [] ->
                    List.reverse acc

                word :: rest ->
                    if word == "M" || word == "L" || word == "l" then
                        go rest word at acc

                    else
                        case ( String.toInt word, rest ) of
                            ( Just u, next :: rest2 ) ->
                                case String.toInt next of
                                    Just v ->
                                        case ( command, at ) of
                                            ( "M", _ ) ->
                                                go rest2 "l" (Just ( u, v )) acc

                                            ( "l", Just ( x, y ) ) ->
                                                go rest2 command (Just ( x + u, y + v )) ({ a = ( x, y ), b = ( x + u, y + v ) } :: acc)

                                            ( "L", Just from ) ->
                                                go rest2 command (Just ( u, v )) ({ a = from, b = ( u, v ) } :: acc)

                                            _ ->
                                                go rest2 command (Just ( u, v )) acc

                                    Nothing ->
                                        go rest command at acc

                            _ ->
                                go rest command at acc
    in
    go tokens "M" Nothing []


cell : Float -> Int
cell v =
    floor (v / cellSize)


toFloats : Node -> ( Float, Float )
toFloats ( x, y ) =
    ( toFloat x, toFloat y )


distance : ( Float, Float ) -> ( Float, Float ) -> Float
distance ( ax, ay ) ( bx, by ) =
    sqrt ((ax - bx) ^ 2 + (ay - by) ^ 2)


{-| A fix, moved onto a street (the point on it, and which segment), or
left where it was.
-}
type Fix
    = OnStreet ( Float, Float ) Segment
    | OffStreet ( Float, Float )


{-| A stretch of the path walked, in map coordinates, redrawn along the
streets.
-}
snap : Network -> List ( Float, Float ) -> List ( Float, Float )
snap network points =
    case List.map (place network) points of
        [] ->
            []

        first :: rest ->
            List.foldl
                (\fix ( previous, acc ) -> ( fix, List.reverse (between network previous fix) ++ acc ))
                ( first, [ pointOf first ] )
                rest
                |> Tuple.second
                |> List.reverse
                |> dropRepeats
                |> dropSpikes


pointOf : Fix -> ( Float, Float )
pointOf fix =
    case fix of
        OnStreet point _ ->
            point

        OffStreet point ->
            point


{-| A fix on the nearest street within `maxSnap`, if there is one.
-}
place : Network -> ( Float, Float ) -> Fix
place (Network net) (( px, py ) as point) =
    let
        ( cx, cy ) =
            ( cell px, cell py )

        nearby =
            List.range (cx - 1) (cx + 1)
                |> List.concatMap (\x -> List.range (cy - 1) (cy + 1) |> List.concatMap (\y -> Dict.get ( x, y ) net.cells |> Maybe.withDefault []))
                |> List.filterMap (\i -> Array.get i net.segments)
                |> List.map (\seg -> ( seg, nearestOn seg point ))
                |> List.sortBy (\( _, onSeg ) -> distance onSeg point)
                |> List.head
    in
    case nearby of
        Just ( seg, onSeg ) ->
            if distance onSeg point <= maxSnap then
                OnStreet onSeg seg

            else
                OffStreet point

        Nothing ->
            OffStreet point


{-| The point on a segment nearest `p`.
-}
nearestOn : Segment -> ( Float, Float ) -> ( Float, Float )
nearestOn seg ( px, py ) =
    let
        ( ax, ay ) =
            toFloats seg.a

        ( bx, by ) =
            toFloats seg.b

        ( dx, dy ) =
            ( bx - ax, by - ay )

        lengthSquared =
            dx * dx + dy * dy

        t =
            if lengthSquared == 0 then
                0

            else
                clamp 0 1 (((px - ax) * dx + (py - ay) * dy) / lengthSquared)
    in
    ( ax + t * dx, ay + t * dy )


{-| The points after `from` up to and including `to`: along the streets
if both are on one and there's a way there that isn't too long, straight
otherwise.
-}
between : Network -> Fix -> Fix -> List ( Float, Float )
between network from to =
    case ( from, to ) of
        ( OnStreet start startSeg, OnStreet end endSeg ) ->
            if startSeg == endSeg then
                [ end ]

            else
                case route network ( start, startSeg ) ( end, endSeg ) of
                    Just corners ->
                        List.map toFloats corners ++ [ end ]

                    Nothing ->
                        [ end ]

        _ ->
            [ pointOf to ]


{-| The corners along the shortest way through the network from a point
on one segment to a point on another (Dijkstra's algorithm, from both ends
of the first, to either end of the last), or Nothing if the way is too long
(`maxDetour`) or there isn't one.
-}
route : Network -> ( ( Float, Float ), Segment ) -> ( ( Float, Float ), Segment ) -> Maybe (List Node)
route (Network net) ( start, startSeg ) ( end, endSeg ) =
    let
        limit =
            distance start end * maxDetour.times + maxDetour.plus

        -- Left to go from a corner to the end, if it's an end of the last
        -- segment.
        finish node =
            if node == endSeg.a || node == endSeg.b then
                Just (distance (toFloats node) end)

            else
                Nothing

        -- The frontier is keyed by (cost so far, corner), so its first
        -- entry is the cheapest; each entry holds the corner it was
        -- reached from. `settled` keeps that for each corner done, to
        -- trace the way back.
        search frontier settled best =
            case Dict.toList frontier |> List.head of
                Nothing ->
                    ( settled, best )

                Just ( ( cost, x, y ) as key, previous ) ->
                    let
                        node =
                            ( x, y )

                        rest =
                            Dict.remove key frontier

                        bestCost =
                            Maybe.map Tuple.first best |> Maybe.withDefault limit
                    in
                    if cost >= bestCost then
                        ( settled, best )

                    else if Dict.member node settled then
                        search rest settled best

                    else
                        let
                            nowSettled =
                                Dict.insert node previous settled

                            nowBest =
                                case finish node of
                                    Just left ->
                                        if cost + left < bestCost then
                                            Just ( cost + left, node )

                                        else
                                            best

                                    Nothing ->
                                        best

                            onward =
                                Dict.get node net.neighbours
                                    |> Maybe.withDefault []
                                    |> List.filter (\( next, _ ) -> not (Dict.member next nowSettled))
                                    |> List.foldl
                                        (\( ( nx, ny ), length ) -> Dict.insert ( cost + length, nx, ny ) (Just node))
                                        rest
                        in
                        search onward nowSettled nowBest

        startFrontier =
            [ startSeg.a, startSeg.b ]
                |> List.foldl (\(( x, y ) as node) -> Dict.insert ( distance start (toFloats node), x, y ) Nothing) Dict.empty

        ( trail, found ) =
            search startFrontier Dict.empty Nothing

        traceBack node acc =
            case Dict.get node trail of
                Just (Just previous) ->
                    traceBack previous (node :: acc)

                _ ->
                    node :: acc
    in
    Maybe.map (\( _, last ) -> traceBack last []) found


{-| Out and straight back to where it was (a fix that landed for a moment
on a side street, or across an intersection): the trip is dropped. As a
stack, so a spike off a spike goes too.
-}
dropSpikes : List ( Float, Float ) -> List ( Float, Float )
dropSpikes points =
    List.foldl
        (\p stack ->
            case stack of
                _ :: a :: rest ->
                    if p == a then
                        a :: rest

                    else
                        p :: stack

                _ ->
                    p :: stack
        )
        []
        points
        |> List.reverse


dropRepeats : List ( Float, Float ) -> List ( Float, Float )
dropRepeats points =
    List.foldr
        (\p acc ->
            case acc of
                q :: _ ->
                    if p == q then
                        acc

                    else
                        p :: acc

                [] ->
                    [ p ]
        )
        []
        points
