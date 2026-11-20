module Burndown exposing (Config, Input, Marks, Visible, scrollerId, steps, track, view, window)

{-| /live's timeline: a burndown chart of the McDonald's still to visit,
plan against actual, scrolling sideways an hour at a time
(website/LIVE-DESIGN.md, "Timeline").

Down the side, the McDonald's left (all of them at the top, none at the
bottom), on an axis that stays put; across, New York time, about three
hours to a screen, from the hour before the plan's first arrival to the
hour after its last departure (or now, if the walk runs over). The chart
slides under the axis and settles with an hour's line at its left edge
(CSS scroll snapping, one hour per swipe). The plan is a grey staircase,
stepping down at each expected arrival; what's actually happened is a red
one, stepping down at each store's first check-in, up to now. Marks
(/live's posts) sit on the red line at their time.

Under it, the whole day small: both lines, with the part on screen
highlighted; tapping or dragging it jumps there.

The chart is an SVG stretched to fill its box (preserveAspectRatio none),
its lines kept their width with non-scaling strokes, like /live's map; the
ruler and the numbers are drawn at their own size, placed by percentage.

-}

import Html exposing (Html)
import Icon
import Html.Attributes as Attr
import Html.Events as Events
import Json.Decode as Decode
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


{-| Marks on the red line, each at a time, drawn by a function given where
it is as fractions of the chart; those outside the chart's span are left
off. `key`: what the marks are, for the key (none without marks).
-}
type alias Marks msg =
    { items : List { at : Int, draw : { x : Float, y : Float } -> Html msg }
    , key : String
    }


{-| How far the chart is scrolled, in pixels: from its left, how much is
on screen, and how wide it all is.
-}
type alias Visible =
    { left : Float
    , width : Float
    , scene : Float
    }


{-| What the chart reports: a scroll (for the day strip), a jump on the
strip (to a fraction of the day, to centre), and a mouse drag starting on
the chart (at this x, scrolled this far; Live.elm scrolls it as the mouse
moves), and a press of the ← or → buttons (-1 or 1: an hour back or on). `visible`: what's on screen, once known; `dragging`: while the
mouse drags it, scroll snapping is off (it settles when let go).
-}
type alias Config msg =
    { scrolled : Visible -> msg
    , jump : Float -> msg
    , dragStart : Float -> Float -> msg
    , step : Int -> msg
    , visible : Maybe Visible
    , dragging : Bool
    }


scrollerId : String
scrollerId =
    "burndown-scroller"


{-| The chart's span, whole hours: the hour the window starts in to the
hour after it ends.
-}
track : Input -> Maybe ( Int, Int )
track input =
    window input
        |> Maybe.map
            (\( start, end ) ->
                let
                    floorHour t =
                        t - modBy hourMs (modBy (24 * hourMs) (NewYorkTime.minuteOfWeek t * 60000) + modBy 60000 t)

                    endHour =
                        floorHour end
                in
                ( floorHour start
                , if endHour == end then
                    end

                  else
                    endHour + hourMs
                )
            )


view : Config msg -> Marks msg -> Input -> Html msg
view config marks input =
    case track input of
        Nothing ->
            Html.p [ Attr.class "tab-empty" ] [ Html.text "No route plan loaded." ]

        Just ( start, end ) ->
            let
                span =
                    toFloat (max 1 (end - start))

                hoursLong =
                    (end - start) // hourMs

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
                    input.now >= start && not (List.isEmpty input.visits)

                upToNow =
                    min input.now end

                planned =
                    steps input.total start end input.plan

                actual =
                    steps input.total start upToNow input.visits

                -- McDonald's left on the red line at a time.
                leftAt t =
                    steps input.total start t input.visits |> List.reverse |> List.head |> Maybe.map Tuple.second |> Maybe.withDefault input.total

                levels =
                    -- Every ten, and the total at the top.
                    (input.total :: List.map ((*) 10) (List.range 0 (input.total // 10)))
                        |> List.filter (\left -> left <= input.total)
                        |> List.sort

                hours =
                    List.range 0 hoursLong |> List.map (\i -> start + i * hourMs)

                shown =
                    List.filter (\mark -> mark.at >= start && mark.at <= min end input.now) marks.items

                lines =
                    [ line "burndown-plan" planned ]
                        ++ (if started then
                                [ line "burndown-actual" actual ]

                            else
                                []
                           )

                visibleScroll =
                    Decode.map3 Visible
                        (Decode.at [ "target", "scrollLeft" ] Decode.float)
                        (Decode.at [ "target", "clientWidth" ] Decode.float)
                        (Decode.at [ "target", "scrollWidth" ] Decode.float)

                -- Where on the strip a pointer is, as a fraction of it.
                stripAt =
                    Decode.map2 (\offset width -> clamp 0 1 (offset / max 1 width))
                        (Decode.field "offsetX" Decode.float)
                        (Decode.at [ "currentTarget", "clientWidth" ] Decode.float)

                pressed =
                    Decode.field "buttons" Decode.int
                        |> Decode.andThen
                            (\buttons ->
                                if buttons > 0 then
                                    Decode.map config.jump stripAt

                                else
                                    Decode.fail "not pressed"
                            )
            in
            Html.div [ Attr.class "burndown" ]
                [ Html.div [ Attr.class "burndown-levels" ]
                    (List.map
                        (\left ->
                            Html.span
                                [ Attr.class "burndown-level", Attr.style "top" (pct (y left)) ]
                                [ Html.text (String.fromInt left) ]
                        )
                        levels
                    )
                , Html.div
                    [ Attr.class "burndown-scroller"
                    , Attr.classList [ ( "burndown-dragging", config.dragging ) ]
                    , Attr.id scrollerId
                    , Attr.tabindex 0
                    , Attr.attribute "aria-label" "Timeline, an hour at a time"
                    , Events.on "scroll" (Decode.map config.scrolled visibleScroll)
                    , Events.preventDefaultOn "mousedown"
                        (Decode.map3 (\button cx left -> ( button, config.dragStart cx left ))
                            (Decode.field "button" Decode.int)
                            (Decode.field "clientX" Decode.float)
                            (Decode.at [ "currentTarget", "scrollLeft" ] Decode.float)
                            |> Decode.andThen
                                (\( button, msg ) ->
                                    if button == 0 then
                                        Decode.succeed ( msg, True )

                                    else
                                        Decode.fail "not the main button"
                                )
                        )
                    ]
                    [ Html.div [ Attr.class "burndown-track", Attr.style "width" ("calc(" ++ String.fromInt hoursLong ++ " * 100cqw / 3)") ]
                        (List.map
                            (\t ->
                                Html.div [ Attr.class "burndown-hour", Attr.style "left" (pct (x t)) ]
                                    [ if t < end then
                                        Html.span [ Attr.class "burndown-hour-label" ] [ Html.text (formatHour (modBy 1440 (NewYorkTime.minuteOfWeek t) // 60)) ]

                                      else
                                        Html.text ""
                                    ]
                            )
                            hours
                            ++ [ Html.div [ Attr.class "burndown-plot" ]
                                    [ Svg.svg
                                        [ SvgAttr.viewBox ("0 0 " ++ String.fromFloat scale ++ " " ++ String.fromFloat scale)
                                        , SvgAttr.preserveAspectRatio "none"
                                        , Attr.attribute "role" "img"
                                        , Attr.attribute "aria-label" "McDonald's still to visit over time: the plan, and what's actually happened so far"
                                        ]
                                        (List.map
                                            (\t ->
                                                Svg.line [ SvgAttr.class "burndown-grid", SvgAttr.x1 (String.fromFloat (x t)), SvgAttr.x2 (String.fromFloat (x t)), SvgAttr.y1 "0", SvgAttr.y2 (String.fromFloat scale) ] []
                                            )
                                            hours
                                            ++ List.map
                                                (\left ->
                                                    Svg.line [ SvgAttr.class "burndown-grid", SvgAttr.x1 "0", SvgAttr.x2 (String.fromFloat scale), SvgAttr.y1 (String.fromFloat (y left)), SvgAttr.y2 (String.fromFloat (y left)) ] []
                                                )
                                                levels
                                            ++ lines
                                            ++ (if input.now >= start && input.now <= end then
                                                    [ Svg.line [ SvgAttr.class "burndown-now", SvgAttr.x1 (String.fromFloat (x input.now)), SvgAttr.x2 (String.fromFloat (x input.now)), SvgAttr.y1 "0", SvgAttr.y2 (String.fromFloat scale) ] [] ]

                                                else
                                                    []
                                               )
                                        )
                                    , Html.div [ Attr.class "burndown-marks" ]
                                        (List.map
                                            (\mark ->
                                                let
                                                    across =
                                                        toFloat (mark.at - start) / span

                                                    down =
                                                        y (leftAt mark.at) / scale
                                                in
                                                Html.div
                                                    [ Attr.class "burndown-mark"
                                                    , Attr.style "left" (String.fromFloat (across * 100) ++ "%")
                                                    , Attr.style "top" (String.fromFloat (down * 100) ++ "%")
                                                    ]
                                                    [ mark.draw { x = across, y = down } ]
                                            )
                                            shown
                                        )
                                    ]
                               ]
                        )
                    ]
                , viewStepButtons config
                , Html.div
                    [ Attr.class "burndown-strip"
                    , Attr.attribute "aria-hidden" "true"
                    , Events.on "pointerdown" (Decode.map config.jump stripAt)
                    , Events.on "pointermove" pressed
                    ]
                    [ Svg.svg
                        [ SvgAttr.viewBox ("0 0 " ++ String.fromFloat scale ++ " " ++ String.fromFloat scale)
                        , SvgAttr.preserveAspectRatio "none"
                        ]
                        lines
                    , case config.visible of
                        Just v ->
                            Html.span
                                [ Attr.class "burndown-strip-window"
                                , Attr.style "left" (String.fromFloat (v.left / max 1 v.scene * 100) ++ "%")
                                , Attr.style "width" (String.fromFloat (v.width / max 1 v.scene * 100) ++ "%")
                                ]
                                []

                        Nothing ->
                            Html.text ""
                    ]
                , Html.div [ Attr.class "burndown-strip-labels" ]
                    [ Html.span [] [ Html.text (formatHour (modBy 1440 (NewYorkTime.minuteOfWeek start) // 60)) ]
                    , Html.span [ Attr.class "burndown-key" ]
                        ([ Html.span [ Attr.class "burndown-key-plan" ] [ Html.text "Plan" ]
                         , Html.span [ Attr.class "burndown-key-actual" ] [ Html.text "Actual" ]
                         ]
                            ++ (if List.isEmpty shown then
                                    []

                                else
                                    [ Html.span [ Attr.class "burndown-key-marks" ] [ Html.text marks.key ] ]
                               )
                        )
                    , Html.span [] [ Html.text (formatHour (modBy 1440 (NewYorkTime.minuteOfWeek end) // 60)) ]
                    ]
                ]


{-| ← and →, over the chart's top right (like the map's + and -): an hour
back or on, for a mouse (a finger or a trackpad can just swipe). Each is
off at its end of the day.
-}
viewStepButtons : Config msg -> Html msg
viewStepButtons config =
    let
        ( atStart, atEnd ) =
            case config.visible of
                Just v ->
                    ( v.left <= 1, v.left + v.width >= v.scene - 1 )

                Nothing ->
                    ( False, False )

        button by icon label off =
            Html.button
                [ Attr.type_ "button"
                , Events.onClick (config.step by)
                , Attr.disabled off
                , Attr.attribute "aria-label" label
                ]
                [ Icon.view icon ]
    in
    Html.div [ Attr.class "burndown-step" ]
        [ button -1 Icon.Previous "An hour back" atStart
        , button 1 Icon.Next "An hour on" atEnd
        ]


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
