module Burndown exposing (Input, steps, view, window)

{-| /live's timeline: a burndown chart of the McDonald's still to visit,
plan against actual, under a time ruler like the simulator's
(Simulator.elm, viewTimeAxis).

Down the side, the McDonald's left (all of them at the top, none at the
bottom); across, New York time from the plan's first arrival to its last
departure (or to now, if the walk runs over). The plan is a grey staircase,
stepping down at each expected arrival; what's actually happened is a red
one, stepping down at each store's first check-in, up to now.

The chart is an SVG stretched to fill its box (preserveAspectRatio none),
its lines kept their width with non-scaling strokes, like /live's map; the
ruler and the numbers are drawn at their own size, placed by percentage.

-}

import Html exposing (Html)
import Html.Attributes as Attr
import NewYorkTime
import Svg exposing (Svg)
import Svg.Attributes as SvgAttr


{-| `plan`: each store's expected arrival, and `planEnd`, the last
departure; `visits`: when each store visited so far was first checked in
at; `total`: how many stores; all times ms since the epoch.
-}
type alias Input =
    { plan : List Int
    , planEnd : Int
    , visits : List Int
    , total : Int
    , now : Int
    }


{-| The chart's time span: the plan's first arrival to its last departure,
or on to now if that's later the same day (the walk running over).
-}
window : Input -> Maybe ( Int, Int )
window input =
    List.minimum input.plan
        |> Maybe.map
            (\start ->
                ( start
                , if input.now > input.planEnd && input.now < start + 24 * hourMs then
                    input.now

                  else
                    input.planEnd
                )
            )


{-| A staircase of (time, McDonald's left) corners from `from` to `to`: all
`total` left before any of `times`, one fewer at each. Times before `from`
are already done when it starts; times after `to` don't happen.
-}
steps : Int -> Int -> Int -> List Int -> List ( Int, Int )
steps total from to times =
    let
        sorted =
            List.sort times

        alreadyDone =
            List.length (List.filter (\t -> t < from) sorted)

        during =
            List.filter (\t -> t >= from && t <= to) sorted

        ( corners, left ) =
            List.foldl
                (\t ( acc, remaining ) -> ( ( t, remaining - 1 ) :: ( t, remaining ) :: acc, remaining - 1 ))
                ( [ ( from, total - alreadyDone ) ], total - alreadyDone )
                during
    in
    List.reverse (( to, left ) :: corners)


hourMs : Int
hourMs =
    3600000


{-| The chart's own coordinates: 1000 across the time span, 1000 from all
left (0) to none left (1000).
-}
scale : Float
scale =
    1000


view : Input -> Html msg
view input =
    case window input of
        Nothing ->
            Html.p [ Attr.class "tab-empty" ] [ Html.text "No route plan loaded." ]

        Just ( start, end ) ->
            let
                span =
                    toFloat (max 1 (end - start))

                x t =
                    toFloat (t - start) / span * scale

                y left =
                    toFloat (input.total - left) / toFloat (max 1 input.total) * scale

                pct value =
                    String.fromFloat (value / scale * 100) ++ "%"

                line class corners =
                    Svg.polyline
                        [ SvgAttr.class class
                        , SvgAttr.points
                            (corners
                                |> List.map (\( t, left ) -> String.fromFloat (x t) ++ "," ++ String.fromFloat (y left))
                                |> String.join " "
                            )
                        ]
                        []

                started =
                    input.now >= start

                upToNow =
                    min input.now end

                planned =
                    steps input.total start end input.plan

                actual =
                    steps input.total start upToNow input.visits

                leftAt corners =
                    corners |> List.reverse |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault input.total

                plannedByNow =
                    leftAt (steps input.total start upToNow input.plan)

                actuallyLeft =
                    leftAt actual

                levels =
                    -- Every ten, and the total at the top.
                    (input.total :: List.map ((*) 10) (List.range 0 (input.total // 10)))
                        |> List.filter (\left -> left <= input.total)
                        |> List.sort

                hours =
                    hourTicks start end
            in
            Html.div [ Attr.class "burndown" ]
                [ Html.p [ Attr.class "burndown-summary" ]
                    [ Html.text
                        (if started then
                            String.fromInt actuallyLeft
                                ++ " to go"
                                ++ (if input.now <= end then
                                        "; the plan says " ++ String.fromInt plannedByNow ++ " by now."

                                    else
                                        "."
                                   )

                         else
                            String.fromInt (input.total - List.length input.visits) ++ " to go. Starts " ++ NewYorkTime.format start ++ "."
                        )
                    , Html.span [ Attr.class "burndown-key" ]
                        [ Html.span [ Attr.class "burndown-key-plan" ] [ Html.text "Plan" ]
                        , Html.span [ Attr.class "burndown-key-actual" ] [ Html.text "Actual" ]
                        ]
                    ]
                , Html.div [] []
                , viewRuler start end
                , Html.div [ Attr.class "burndown-levels" ]
                    (List.map
                        (\left ->
                            Html.span
                                [ Attr.class "burndown-level", Attr.style "top" (pct (y left)) ]
                                [ Html.text (String.fromInt left) ]
                        )
                        levels
                    )
                , Html.div [ Attr.class "burndown-plot" ]
                    [ Svg.svg
                        [ SvgAttr.viewBox ("0 0 " ++ String.fromFloat scale ++ " " ++ String.fromFloat scale)
                        , SvgAttr.preserveAspectRatio "none"
                        , Attr.attribute "role" "img"
                        , Attr.attribute "aria-label" "McDonald's still to visit over time: the plan, and what's actually happened so far"
                        ]
                        (List.map
                            (\( t, _ ) ->
                                Svg.line [ SvgAttr.class "burndown-grid", SvgAttr.x1 (String.fromFloat (x t)), SvgAttr.x2 (String.fromFloat (x t)), SvgAttr.y1 "0", SvgAttr.y2 (String.fromFloat scale) ] []
                            )
                            hours
                            ++ List.map
                                (\left ->
                                    Svg.line [ SvgAttr.class "burndown-grid", SvgAttr.x1 "0", SvgAttr.x2 (String.fromFloat scale), SvgAttr.y1 (String.fromFloat (y left)), SvgAttr.y2 (String.fromFloat (y left)) ] []
                                )
                                levels
                            ++ [ line "burndown-plan" planned ]
                            ++ (if started then
                                    [ line "burndown-actual" actual ]

                                else
                                    []
                               )
                            ++ (if started && input.now <= end then
                                    [ Svg.line [ SvgAttr.class "burndown-now", SvgAttr.x1 (String.fromFloat (x input.now)), SvgAttr.x2 (String.fromFloat (x input.now)), SvgAttr.y1 "0", SvgAttr.y2 (String.fromFloat scale) ] [] ]

                                else
                                    []
                               )
                        )
                    ]
                ]


{-| The hours in the span, as (time, hour of the day in New York).
-}
hourTicks : Int -> Int -> List ( Int, Int )
hourTicks start end =
    quarterTicks start end
        |> List.filterMap
            (\t ->
                let
                    minuteOfDay =
                        modBy 1440 (NewYorkTime.minuteOfWeek t)
                in
                if modBy 60 minuteOfDay == 0 then
                    Just ( t, minuteOfDay // 60 )

                else
                    Nothing
            )


{-| Every quarter hour of New York clock time in the span.
-}
quarterTicks : Int -> Int -> List Int
quarterTicks start end =
    let
        quarterMs =
            15 * 60000

        -- The quarter hour starting the start's minute or after it, then
        -- the next one if that's before the start (a start part-way
        -- through a quarter hour's first minute).
        onOrAfterMinute =
            (start - modBy 60000 start)
                + modBy 15 (15 - modBy 15 (NewYorkTime.minuteOfWeek start))
                * 60000

        first =
            if onOrAfterMinute < start then
                onOrAfterMinute + quarterMs

            else
                onOrAfterMinute
    in
    List.range 0 ((end - first) // quarterMs)
        |> List.map (\i -> first + i * quarterMs)


rulerHeight : Float
rulerHeight =
    26


{-| The time ruler, as the simulator draws it: a tick every 15 minutes,
taller ticks on the hour, and hour labels ("8 AM") every 1, 2, 3, ...
hours, as many as fit (assuming a phone-ish 360px). Labels too close to
either end to fit are left off.
-}
viewRuler : Int -> Int -> Html msg
viewRuler start end =
    let
        span =
            toFloat (max 1 (end - start))

        pct t =
            String.fromFloat (toFloat (t - start) / span * 100) ++ "%"

        hoursLong =
            span / toFloat hourMs

        labelEveryHours =
            [ 1, 2, 3, 4, 6, 12, 24 ]
                |> List.filter (\every -> toFloat every * 360 / hoursLong >= 44)
                |> List.head
                |> Maybe.withDefault 24

        baseline =
            rulerHeight - 2

        tick t =
            let
                minuteOfDay =
                    modBy 1440 (NewYorkTime.minuteOfWeek t)

                isHour =
                    modBy 60 minuteOfDay == 0

                fraction =
                    toFloat (t - start) / span

                tickLine =
                    Svg.line
                        [ SvgAttr.x1 (pct t)
                        , SvgAttr.x2 (pct t)
                        , SvgAttr.y1 (String.fromFloat baseline)
                        , SvgAttr.y2
                            (String.fromFloat
                                (if isHour then
                                    baseline - 8

                                 else
                                    baseline - 4
                                )
                            )
                        , SvgAttr.class "burndown-axis"
                        ]
                        []
            in
            if isHour && modBy labelEveryHours (minuteOfDay // 60) == 0 && fraction > 0.03 && fraction < 0.97 then
                [ tickLine
                , Svg.text_
                    [ SvgAttr.x (pct t)
                    , SvgAttr.y (String.fromFloat (baseline - 11))
                    , SvgAttr.textAnchor "middle"
                    , SvgAttr.class "burndown-axis-label"
                    ]
                    [ Svg.text (formatHour (minuteOfDay // 60)) ]
                ]

            else
                [ tickLine ]
    in
    Svg.svg
        [ SvgAttr.class "burndown-ruler"
        , SvgAttr.width "100%"
        , SvgAttr.height (String.fromFloat rulerHeight)
        ]
        (Svg.line
            [ SvgAttr.x1 "0", SvgAttr.x2 "100%", SvgAttr.y1 (String.fromFloat baseline), SvgAttr.y2 (String.fromFloat baseline), SvgAttr.class "burndown-axis" ]
            []
            :: List.concatMap tick (quarterTicks start end)
        )


{-| An hour of the day (0-23) on a 12-hour clock: "12 AM", "8 PM".
-}
formatHour : Int -> String
formatHour hour =
    String.fromInt
        (if modBy 12 hour == 0 then
            12

         else
            modBy 12 hour
        )
        ++ (if hour < 12 then
                " AM"

            else
                " PM"
           )
