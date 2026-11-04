port module MegaSearch exposing (main)

{-| The mega search on mega-search.html: the simulator's search, run for
every start location at every start time across a window (a whole weekend,
say), at one pace and stop length, with the finish left flexible. Each
(start time, start location) pair is one cell of the landscape, searched
from seed 1 by a pool of Web Workers (see `MegaSearchWorker` and the page's
script), in a scattered order so the whole landscape comes into focus at
once instead of filling in left to right.

Results are saved in the browser as they arrive (see the `save` port), so a
long search survives a reload and picks up where it left off. Every cell
links to the simulator with the same settings, which finds the same route
(see `simulatorLink`).

-}

import Array
import Browser
import Calendar
import Dict exposing (Dict)
import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Events
import Html.Lazy
import Json.Decode as Decode
import Json.Encode as Encode
import Link
import List.Extra
import McdData exposing (cities)
import Random
import Search
import Svg exposing (Svg)
import Svg.Attributes as SvgAttr
import Time



-- PORTS


{-| Replaces the pool's queue with these jobs, in order (see `jobs`).
-}
port runJobs : Encode.Value -> Cmd msg


{-| Empties the pool's queue; searches already running still report back.
-}
port stopJobs : () -> Cmd msg


{-| Saves the search (see `encodeSaved`), or clears it given `null`.
-}
port save : Encode.Value -> Cmd msg


port jobDone : (Decode.Value -> msg) -> Sub msg



-- SETTINGS


{-| The settings form's raw values.
-}
type alias Inputs =
    { fromDate : String
    , fromTime : String
    , toDate : String
    , toTime : String
    , step : Int
    , pace : String
    , stop : String
    }


{-| What a search covers: start times every `step` minutes, from
`fromMinutes` past midnight on `fromDate` through `columns` of them, and
every location as the start.
-}
type alias Plan =
    { fromDate : Calendar.Date
    , fromMinutes : Int
    , step : Int
    , columns : Int
    , pace : Float
    , stop : Int
    }


steps : List Int
steps =
    [ 15, 30, 60 ]


{-| The most start times one search covers: a week at 15 minutes.
-}
maxColumns : Int
maxColumns =
    7 * 24 * 4 + 1


plan : Inputs -> Result String Plan
plan inputs =
    case ( Calendar.parseDate inputs.fromDate, Calendar.parseDate inputs.toDate ) of
        ( Just fromDate, Just toDate ) ->
            let
                fromMinutes =
                    Search.parseStartMinutes inputs.fromTime

                -- minutes from fromDate's midnight to the window's end
                toMinutes =
                    dayDiff fromDate toDate * Search.dayLength + Search.parseStartMinutes inputs.toTime

                columns =
                    (toMinutes - fromMinutes) // inputs.step + 1
            in
            if toMinutes < fromMinutes then
                Err "The window ends before it starts."

            else if columns > maxColumns then
                Err "That window is too long. Try a week or less, or a longer step."

            else
                Ok
                    { fromDate = fromDate
                    , fromMinutes = fromMinutes
                    , step = inputs.step
                    , columns = columns
                    , pace = Search.parseMinutesPerMile inputs.pace
                    , stop = Search.parseStopMinutes inputs.stop
                    }

        _ ->
            Err "Pick a start and end date."


dayDiff : Calendar.Date -> Calendar.Date -> Int
dayDiff from to =
    -- Calendar has no difference function; count up to a year either way.
    List.range -366 366
        |> List.Extra.find (\n -> Calendar.addDays n from == to)
        |> Maybe.withDefault 0


{-| A column's start: its date, minutes past that midnight, and weekday
(Monday-indexed, as `Search.StartTime` wants).
-}
type alias Column =
    { date : Calendar.Date
    , minutes : Int
    , weekday : Int
    }


column : Plan -> Int -> Column
column p col =
    let
        absolute =
            p.fromMinutes + col * p.step

        (( y, m, d ) as date) =
            Calendar.addDays (absolute // Search.dayLength) p.fromDate
    in
    { date = date
    , minutes = modBy Search.dayLength absolute
    , weekday = modBy 7 (Calendar.sakamotoWeekday y m d + 6)
    }


cityCount : Int
cityCount =
    Array.length cities


cellCount : Plan -> Int
cellCount p =
    p.columns * cityCount



-- MODEL


type alias Cell =
    ( Int, Int )


{-| A searched cell's best route: total minutes (waits included), walking
meters, and the city index it finishes at.
-}
type alias Outcome =
    { minutes : Int
    , meters : Int
    , finish : Int
    }


type Status
    = Idle
    | Running
    | Paused
    | Done


type alias Model =
    { inputs : Inputs
    , active : Maybe Plan
    , results : Dict Cell Outcome
    , status : Status
    , hovered : Maybe Cell
    , pinned : Maybe Cell
    , workers : Int
    , now : Int
    , runStart : Maybe { at : Int, done : Int }
    }


type alias Flags =
    { defaultDate : String
    , workers : Int
    , saved : Decode.Value
    }


init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        fresh =
            { inputs = defaultInputs flags.defaultDate
            , active = Nothing
            , results = Dict.empty
            , status = Idle
            , hovered = Nothing
            , pinned = Nothing
            , workers = flags.workers
            , now = 0
            , runStart = Nothing
            }
    in
    case Decode.decodeValue savedDecoder flags.saved of
        Ok saved ->
            case plan saved.inputs of
                Ok p ->
                    let
                        results =
                            saved.results |> List.filter (inPlan p << Tuple.first) |> Dict.fromList
                    in
                    ( { fresh
                        | inputs = saved.inputs
                        , active = Just p
                        , results = results
                        , status =
                            if Dict.size results >= cellCount p then
                                Done

                            else
                                Paused
                      }
                    , Cmd.none
                    )

                Err _ ->
                    ( fresh, Cmd.none )

        Err _ ->
            ( fresh, Cmd.none )


inPlan : Plan -> Cell -> Bool
inPlan p ( col, city ) =
    col >= 0 && col < p.columns && city >= 0 && city < cityCount


{-| From 6 PM the day before `date` (the McTrot date) to 6 PM the day after,
every 30 minutes, at the simulator's default pace and stop length.
-}
defaultInputs : String -> Inputs
defaultInputs date =
    let
        shifted n =
            Calendar.parseDate date
                |> Maybe.map (Calendar.addDays n >> Calendar.formatIso)
                |> Maybe.withDefault date
    in
    { fromDate = shifted -1
    , fromTime = "18:00"
    , toDate = shifted 1
    , toTime = "18:00"
    , step = 30
    , pace = String.fromFloat Search.defaultMinutesPerMile
    , stop = String.fromInt Search.defaultStopMinutes
    }



-- UPDATE


type Msg
    = SetFromDate String
    | SetFromTime String
    | SetToDate String
    | SetToTime String
    | SetStep String
    | SetPace String
    | SetStop String
    | Start
    | Pause
    | Resume
    | StartOver
    | JobDone Decode.Value
    | Hover (Maybe Cell)
    | Pin Cell
    | Tick Time.Posix


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        setInputs f =
            ( { model | inputs = f model.inputs }, Cmd.none )
    in
    case msg of
        SetFromDate v ->
            setInputs (\i -> { i | fromDate = v })

        SetFromTime v ->
            setInputs (\i -> { i | fromTime = v })

        SetToDate v ->
            setInputs (\i -> { i | toDate = v })

        SetToTime v ->
            setInputs (\i -> { i | toTime = v })

        SetStep v ->
            setInputs (\i -> { i | step = String.toInt v |> Maybe.withDefault i.step })

        SetPace v ->
            setInputs (\i -> { i | pace = v })

        SetStop v ->
            setInputs (\i -> { i | stop = v })

        Start ->
            case plan model.inputs of
                Ok p ->
                    run { model | active = Just p, results = Dict.empty, pinned = Nothing }

                Err _ ->
                    ( model, Cmd.none )

        Resume ->
            run model

        Pause ->
            ( { model | status = Paused, runStart = Nothing }, stopJobs () )

        StartOver ->
            ( { model | status = Idle, active = Nothing, results = Dict.empty, pinned = Nothing, hovered = Nothing, runStart = Nothing }
            , Cmd.batch [ stopJobs (), save Encode.null ]
            )

        JobDone value ->
            case ( model.active, Decode.decodeValue outcomeDecoder value ) of
                ( Just p, Ok ( cell, outcome ) ) ->
                    if inPlan p cell && model.status /= Idle then
                        let
                            results =
                                Dict.insert cell outcome model.results

                            complete =
                                Dict.size results >= cellCount p

                            next =
                                { model
                                    | results = results
                                    , status =
                                        if complete then
                                            Done

                                        else
                                            model.status
                                    , runStart =
                                        if complete then
                                            Nothing

                                        else
                                            model.runStart
                                }
                        in
                        ( next, save (encodeSaved next) )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        Hover cell ->
            ( { model | hovered = cell }, Cmd.none )

        Pin cell ->
            ( { model
                | pinned =
                    if model.pinned == Just cell then
                        Nothing

                    else
                        Just cell
              }
            , Cmd.none
            )

        Tick t ->
            let
                now =
                    Time.posixToMillis t
            in
            ( { model
                | now = now
                , runStart =
                    case model.runStart of
                        Nothing ->
                            if model.status == Running then
                                Just { at = now, done = Dict.size model.results }

                            else
                                Nothing

                        started ->
                            started
              }
            , Cmd.none
            )


{-| Sends every unsearched cell of the active plan to the workers.
-}
run : Model -> ( Model, Cmd Msg )
run model =
    case model.active of
        Just p ->
            let
                next =
                    { model | status = Running, runStart = Nothing }
            in
            ( next
            , Cmd.batch
                [ runJobs (Encode.list (encodeJob p) (jobs p model.results))
                , save (encodeSaved next)
                ]
            )

        Nothing ->
            ( model, Cmd.none )


{-| Every cell not yet in `results`, in a shuffled order (the same every
time), so early results sample the whole landscape.
-}
jobs : Plan -> Dict Cell Outcome -> List Cell
jobs p results =
    let
        n =
            cellCount p

        ( keys, _ ) =
            Random.step (Random.list n (Random.float 0 1)) (Random.initialSeed 21)
    in
    List.map2 Tuple.pair keys (List.range 0 (n - 1))
        |> List.sortBy Tuple.first
        |> List.map (\( _, i ) -> ( i // cityCount, modBy cityCount i ))
        |> List.filter (\cell -> not (Dict.member cell results))


{-| Every cell is searched from the simulator's default seed, so its
simulator link (see `simulatorLink`) finds the same route.
-}
seed : Int
seed =
    1


encodeJob : Plan -> Cell -> Encode.Value
encodeJob p (( col, city ) as cell) =
    let
        c =
            column p col
    in
    Encode.object
        [ ( "id", Encode.string (cellId cell) )
        , ( "weekday", Encode.int c.weekday )
        , ( "minutes", Encode.int c.minutes )
        , ( "pace", Encode.float p.pace )
        , ( "stop", Encode.int p.stop )
        , ( "startCity", Encode.int city )
        , ( "seed", Encode.int seed )
        ]


cellId : Cell -> String
cellId ( col, city ) =
    String.fromInt col ++ "-" ++ String.fromInt city


outcomeDecoder : Decode.Decoder ( Cell, Outcome )
outcomeDecoder =
    Decode.map4
        (\id minutes meters finish ->
            ( id, { minutes = minutes, meters = meters, finish = finish } )
        )
        (Decode.field "id" Decode.string
            |> Decode.andThen
                (\id ->
                    case String.split "-" id |> List.map String.toInt of
                        [ Just col, Just city ] ->
                            Decode.succeed ( col, city )

                        _ ->
                            Decode.fail "bad id"
                )
        )
        (Decode.field "minutes" Decode.int)
        (Decode.field "meters" Decode.int)
        (Decode.field "finish" Decode.int)



-- SAVING


{-| The settings and every result, each as `[col, city, minutes, meters,
finish]`.
-}
encodeSaved : Model -> Encode.Value
encodeSaved model =
    Encode.object
        [ ( "inputs"
          , Encode.object
                [ ( "fromDate", Encode.string model.inputs.fromDate )
                , ( "fromTime", Encode.string model.inputs.fromTime )
                , ( "toDate", Encode.string model.inputs.toDate )
                , ( "toTime", Encode.string model.inputs.toTime )
                , ( "step", Encode.int model.inputs.step )
                , ( "pace", Encode.string model.inputs.pace )
                , ( "stop", Encode.string model.inputs.stop )
                ]
          )
        , ( "results"
          , Dict.toList model.results
                |> Encode.list
                    (\( ( col, city ), o ) -> Encode.list Encode.int [ col, city, o.minutes, o.meters, o.finish ])
          )
        ]


savedDecoder : Decode.Decoder { inputs : Inputs, results : List ( Cell, Outcome ) }
savedDecoder =
    Decode.map2 (\inputs results -> { inputs = inputs, results = results })
        (Decode.field "inputs"
            (Decode.map7 Inputs
                (Decode.field "fromDate" Decode.string)
                (Decode.field "fromTime" Decode.string)
                (Decode.field "toDate" Decode.string)
                (Decode.field "toTime" Decode.string)
                (Decode.field "step" Decode.int)
                (Decode.field "pace" Decode.string)
                (Decode.field "stop" Decode.string)
            )
        )
        (Decode.field "results"
            (Decode.list
                (Decode.list Decode.int
                    |> Decode.andThen
                        (\row ->
                            case row of
                                [ col, city, minutes, meters, finish ] ->
                                    Decode.succeed ( ( col, city ), { minutes = minutes, meters = meters, finish = finish } )

                                _ ->
                                    Decode.fail "bad result"
                        )
                )
            )
        )


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ jobDone JobDone
        , if model.status == Running then
            Time.every 1000 Tick

          else
            Sub.none
        ]



-- VIEW


view : Model -> Html Msg
view model =
    Html.div [ Attr.class "sim mega" ]
        [ Html.div [ Attr.class "sim-top" ]
            [ Html.a [ Attr.class "sim-home", Attr.href "/" ] [ Html.text "← McTrot" ]
            , Html.p [ Attr.class "sim-status", Attr.attribute "role" "status" ] [ Html.text (statusText model) ]
            ]
        , Html.h1 [ Attr.class "mega-title" ] [ Html.text "Mega Search" ]
        , Html.p [ Attr.class "mega-intro" ]
            [ Html.text "Runs the "
            , Html.a [ Attr.href "simulator.html" ] [ Html.text "simulator" ]
            , Html.text "’s search from every McDonald’s, at every start time in a window, and maps how long each route takes. It can take an hour. Leave the tab open; results are saved as they come in."
            ]
        , viewSettings model
        , Html.div [ Attr.class "bezel mega-screen" ]
            (case model.active of
                Just p ->
                    viewLandscape model p

                Nothing ->
                    [ Html.p [ Attr.class "mega-empty" ] [ Html.text "Pick a window, pace, and stop length, then START." ] ]
            )
        ]


statusText : Model -> String
statusText model =
    case model.status of
        Idle ->
            "Ready"

        Running ->
            "Searching"

        Paused ->
            "Paused"

        Done ->
            "Done"


viewSettings : Model -> Html Msg
viewSettings model =
    let
        locked =
            model.status /= Idle

        planned =
            plan model.inputs

        input type_ value toMsg extra =
            Html.input
                ([ Attr.type_ type_
                 , Attr.value value
                 , Events.onInput toMsg
                 , Attr.disabled locked
                 ]
                    ++ extra
                )
                []

        field label control =
            Html.label [ Attr.class "field" ] [ Html.span [ Attr.class "field-label" ] [ Html.text label ], control ]

        summary =
            case planned of
                Ok p ->
                    String.fromInt p.columns
                        ++ " start times × "
                        ++ String.fromInt cityCount
                        ++ " locations = "
                        ++ formatCount (cellCount p)
                        ++ " routes, on "
                        ++ String.fromInt model.workers
                        ++ (if model.workers == 1 then
                                " thread"

                            else
                                " threads"
                           )

                Err problem ->
                    problem

        button cls label msg enabled =
            Html.div [ Attr.class ("start-well start-sheet " ++ cls) ]
                [ Html.button [ Attr.class "start-button", Events.onClick msg, Attr.disabled (not enabled) ] [ Html.text label ] ]

        buttons =
            case model.status of
                Idle ->
                    [ button "" "Start" Start (isOk planned) ]

                Running ->
                    [ button "" "Pause" Pause True ]

                Paused ->
                    [ button "" "Resume" Resume True, button "mega-secondary" "Start over" StartOver True ]

                Done ->
                    [ button "mega-secondary" "Start over" StartOver True ]
    in
    Html.section [ Attr.class "mega-settings", Attr.attribute "aria-label" "Search settings" ]
        [ Html.div [ Attr.class "settings" ]
            [ field "From" (input "date" model.inputs.fromDate SetFromDate [])
            , field "at" (input "time" model.inputs.fromTime SetFromTime [ Attr.step "900" ])
            , field "To" (input "date" model.inputs.toDate SetToDate [])
            , field "at" (input "time" model.inputs.toTime SetToTime [ Attr.step "900" ])
            , field "Every"
                (Html.select [ Events.onInput SetStep, Attr.disabled locked ]
                    (List.map
                        (\s -> Html.option [ Attr.value (String.fromInt s), Attr.selected (s == model.inputs.step) ] [ Html.text (String.fromInt s ++ " min") ])
                        steps
                    )
                )
            , field "Pace (min/mi)" (input "number" model.inputs.pace SetPace [ Attr.step "0.5", Attr.min "1" ])
            , field "Stop (min)" (input "number" model.inputs.stop SetStop [ Attr.step "1", Attr.min "0" ])
            ]
        , Html.div [ Attr.class "mega-run" ]
            (Html.p [ Attr.class "mega-summary" ] [ Html.text summary ] :: buttons)
        ]


isOk : Result e a -> Bool
isOk r =
    case r of
        Ok _ ->
            True

        Err _ ->
            False


formatCount : Int -> String
formatCount n =
    let
        s =
            String.fromInt n
    in
    if n >= 1000 then
        String.dropRight 3 s ++ "," ++ String.right 3 s

    else
        s



-- LANDSCAPE


viewLandscape : Model -> Plan -> List (Html Msg)
viewLandscape model p =
    let
        best =
            bestCell model.results

        shown =
            case model.hovered of
                Just cell ->
                    Just cell

                Nothing ->
                    case model.pinned of
                        Just cell ->
                            Just cell

                        Nothing ->
                            Maybe.map Tuple.first best
    in
    [ Html.div [ Attr.class "hud" ]
        [ Html.div [ Attr.class "hud-row" ]
            [ Html.span [ Attr.class "hud-label" ] [ Html.text "Best" ]
            , Html.span [ Attr.class "hud-value" ] [ Html.text (best |> Maybe.map (Tuple.second >> .minutes >> Search.formatDuration) |> Maybe.withDefault "—") ]
            , Html.span [ Attr.class "hud-value" ] [ Html.text (best |> Maybe.map (Tuple.second >> .meters >> Search.formatMiles) |> Maybe.withDefault "") ]
            ]
        , Html.p [ Attr.class "hud-meta" ] [ Html.text (progressText model p) ]
        ]
    , viewReadout p model.results shown
    , Html.Lazy.lazy2 viewChart p model.results
    , viewKey
    , Html.Lazy.lazy2 viewTopTable p model.results
    ]


bestCell : Dict Cell Outcome -> Maybe ( Cell, Outcome )
bestCell results =
    Dict.toList results |> List.Extra.minimumBy (Tuple.second >> .minutes)


progressText : Model -> Plan -> String
progressText model p =
    let
        done =
            Dict.size model.results

        total =
            cellCount p

        eta =
            case ( model.status, model.runStart ) of
                ( Running, Just started ) ->
                    let
                        doneSince =
                            done - started.done

                        elapsed =
                            model.now - started.at
                    in
                    if doneSince >= model.workers && elapsed > 0 then
                        " · about " ++ formatEta (round (toFloat (total - done) * toFloat elapsed / toFloat doneSince / 60000)) ++ " to go"

                    else
                        ""

                _ ->
                    ""
    in
    formatCount done ++ " of " ++ formatCount total ++ " routes" ++ eta


formatEta : Int -> String
formatEta minutes =
    if minutes < 1 then
        "a minute"

    else if minutes < 60 then
        String.fromInt minutes ++ " min"

    else
        Search.formatDuration minutes


{-| The hovered cell, else the pinned one, else the best: when and where it
starts, and its route.
-}
viewReadout : Plan -> Dict Cell Outcome -> Maybe Cell -> Html Msg
viewReadout p results shown =
    Html.div [ Attr.class "mega-readout", Attr.attribute "aria-live" "polite" ]
        (case shown of
            Just (( col, city ) as cell) ->
                Html.p [ Attr.class "mega-readout-when" ]
                    [ Html.text (startText p col ++ " from " ++ cityName city) ]
                    :: (case Dict.get cell results of
                            Just o ->
                                [ Html.p [ Attr.class "mega-readout-route" ]
                                    [ Html.strong [] [ Html.text (Search.formatDuration o.minutes) ]
                                    , Html.text (" · " ++ Search.formatMiles o.meters ++ " · finishing at " ++ cityName o.finish)
                                    ]
                                , Html.a [ Attr.class "mega-link", Attr.href (simulatorLink p cell), Attr.target "_blank" ] [ Html.text "Open in simulator ↗" ]
                                ]

                            Nothing ->
                                [ Html.p [ Attr.class "mega-readout-route" ] [ Html.text "Not searched yet" ] ]
                       )

            Nothing ->
                [ Html.p [ Attr.class "mega-readout-when" ] [ Html.text "Results appear here as the routes come in." ] ]
        )


startText : Plan -> Int -> String
startText p col =
    let
        c =
            column p col
    in
    Calendar.formatShort c.date ++ ", " ++ Search.formatClock c.minutes


cityName : Int -> String
cityName city =
    Array.get city cities |> Maybe.map .name |> Maybe.withDefault "?"


{-| The simulator with this cell's settings, which finds the same route (see
`MegaSearchWorker`).
-}
simulatorLink : Plan -> Cell -> String
simulatorLink p ( col, city ) =
    let
        c =
            column p col
    in
    "simulator.html"
        ++ Link.toQuery
            { date = Calendar.formatIso c.date
            , minutes = c.minutes
            , pace = p.pace
            , stop = p.stop
            , seed = seed
            , from = Just city
            , to = Nothing
            }



-- CHART


columnWidth : Plan -> Float
columnWidth p =
    case p.step of
        15 ->
            6

        30 ->
            10

        _ ->
            18


rowHeight : Float
rowHeight =
    15


stripHeight : Float
stripHeight =
    96


axisHeight : Float
axisHeight =
    30


{-| Each start location's row, north to south.
-}
rows : List Int
rows =
    Search.northToSouth


rowOf : Dict Int Int
rowOf =
    rows |> List.indexedMap (\r city -> ( city, r )) |> Dict.fromList


{-| How far over the best a route is, in five steps; the shade gets darker
as it gets slower.
-}
bins : List { below : Int, color : String, label : String }
bins =
    [ { below = 15, color = "#FFD100", label = "Within 15 min of best" }
    , { below = 30, color = "#D4AB00", label = "15–30 min slower" }
    , { below = 60, color = "#9C7F0F", label = "30–60 min slower" }
    , { below = 120, color = "#66551A", label = "1–2 h slower" }
    , { below = 100000, color = "#433B1E", label = "2+ h slower" }
    ]


binColor : Int -> Int -> String
binColor best minutes =
    bins
        |> List.Extra.find (\b -> minutes - best < b.below)
        |> Maybe.map .color
        |> Maybe.withDefault "#433B1E"


viewKey : Html msg
viewKey =
    Html.ul [ Attr.class "sched-key mega-key" ]
        (List.map
            (\b ->
                Html.li []
                    [ Html.span [ Attr.class "swatch", Attr.style "background" b.color ] []
                    , Html.text b.label
                    ]
            )
            bins
        )


{-| The landscape: on top, the fastest route at each start time; below, a
cell for every start time and location. Scrolls sideways, with the location
names pinned at the left.
-}
viewChart : Plan -> Dict Cell Outcome -> Html Msg
viewChart p results =
    let
        w =
            columnWidth p

        width =
            toFloat p.columns * w

        best =
            bestCell results |> Maybe.map (Tuple.second >> .minutes) |> Maybe.withDefault 0

        heatHeight =
            toFloat cityCount * rowHeight
    in
    Html.div [ Attr.class "mega-scroll", Events.onMouseLeave (Hover Nothing) ]
        [ Html.div
            [ Attr.class "mega-grid"
            , Attr.style "grid-template-columns" ("var(--label-width) " ++ String.fromFloat width ++ "px")
            ]
            [ Html.div [ Attr.class "mega-corner mega-strip-label" ] [ Html.text "Fastest at each start time" ]
            , viewStrip p results width
            , Html.div [ Attr.class "mega-corner" ] []
            , viewAxis p width
            , Html.div [ Attr.class "mega-labels" ]
                (List.map
                    (\city -> Html.div [ Attr.class "mega-label", Attr.style "height" (String.fromFloat rowHeight ++ "px") ] [ Html.text (cityName city) ])
                    rows
                )
            , Svg.svg
                [ SvgAttr.width (String.fromFloat width)
                , SvgAttr.height (String.fromFloat heatHeight)
                , SvgAttr.class "mega-heat"
                ]
                (Svg.rect [ SvgAttr.width (String.fromFloat width), SvgAttr.height (String.fromFloat heatHeight), SvgAttr.class "mega-heat-bg" ] []
                    :: (Dict.toList results |> List.map (viewHeatCell p best))
                )
            ]
        ]


viewHeatCell : Plan -> Int -> ( Cell, Outcome ) -> Svg Msg
viewHeatCell p best (( ( col, city ), o ) as entry) =
    let
        w =
            columnWidth p

        row =
            Dict.get city rowOf |> Maybe.withDefault 0
    in
    Svg.rect
        [ SvgAttr.x (String.fromFloat (toFloat col * w))
        , SvgAttr.y (String.fromFloat (toFloat row * rowHeight + 1))
        , SvgAttr.width (String.fromFloat (w - 1))
        , SvgAttr.height (String.fromFloat (rowHeight - 2))
        , SvgAttr.fill (binColor best o.minutes)
        , Events.onMouseEnter (Hover (Just (Tuple.first entry)))
        , Events.onClick (Pin (Tuple.first entry))
        ]
        [ Svg.title [] [ Svg.text (startText p col ++ " from " ++ cityName city ++ ": " ++ Search.formatDuration o.minutes) ] ]


{-| The fastest route found so far at each start time, as a line (broken
where a start time has no results yet), on a scale from the best to the
slowest of those.
-}
viewStrip : Plan -> Dict Cell Outcome -> Float -> Html Msg
viewStrip p results width =
    let
        w =
            columnWidth p

        columnBests =
            Dict.foldl
                (\( col, _ ) o acc ->
                    Dict.update col
                        (\prev ->
                            case prev of
                                Just m ->
                                    Just (min m o.minutes)

                                Nothing ->
                                    Just o.minutes
                        )
                        acc
                )
                Dict.empty
                results

        values =
            Dict.values columnBests

        lo =
            List.minimum values |> Maybe.withDefault 0

        hi =
            List.maximum values |> Maybe.withDefault 0

        pad =
            8

        y minutes =
            if hi == lo then
                stripHeight / 2

            else
                pad + (stripHeight - 2 * pad) * (1 - toFloat (minutes - lo) / toFloat (hi - lo))

        x col =
            toFloat col * w + w / 2

        -- runs of consecutive start times that have results
        segments =
            List.range 0 (p.columns - 1)
                |> List.foldr
                    (\col ( current, done ) ->
                        case Dict.get col columnBests of
                            Just m ->
                                ( ( col, m ) :: current, done )

                            Nothing ->
                                ( [], current :: done )
                    )
                    ( [], [] )
                |> (\( current, done ) -> current :: done)
                |> List.filter (not << List.isEmpty)

        pointsAttr points =
            points |> List.map (\( col, m ) -> String.fromFloat (x col) ++ "," ++ String.fromFloat (y m)) |> String.join " "

        bestCol =
            Dict.toList columnBests |> List.Extra.minimumBy Tuple.second

        gridLine minutes =
            [ Svg.line [ SvgAttr.x1 "0", SvgAttr.x2 (String.fromFloat width), SvgAttr.y1 (String.fromFloat (y minutes)), SvgAttr.y2 (String.fromFloat (y minutes)), SvgAttr.class "mega-grid-line" ] []
            ]
    in
    Html.div [ Attr.class "mega-strip" ]
        [ Svg.svg [ SvgAttr.width (String.fromFloat width), SvgAttr.height (String.fromFloat stripHeight) ]
            ((if List.isEmpty values then
                []

              else
                gridLine lo ++ gridLine hi
             )
                ++ List.map
                    (\points ->
                        if List.length points == 1 then
                            Svg.circle
                                (case points of
                                    ( col, m ) :: _ ->
                                        [ SvgAttr.cx (String.fromFloat (x col)), SvgAttr.cy (String.fromFloat (y m)), SvgAttr.r "1.5", SvgAttr.class "mega-strip-dot" ]

                                    [] ->
                                        []
                                )
                                []

                        else
                            Svg.polyline [ SvgAttr.points (pointsAttr points), SvgAttr.class "mega-strip-line" ] []
                    )
                    segments
                ++ (case bestCol of
                        Just ( col, m ) ->
                            [ Svg.circle [ SvgAttr.cx (String.fromFloat (x col)), SvgAttr.cy (String.fromFloat (y m)), SvgAttr.r "4", SvgAttr.class "mega-strip-best" ] [] ]

                        Nothing ->
                            []
                   )
            )
        , if List.isEmpty values then
            Html.text ""

          else
            Html.div [ Attr.class "mega-strip-scale" ]
                [ Html.span [ Attr.class "mega-scale-hi", Attr.style "top" (String.fromFloat (y hi) ++ "px") ] [ Html.text (Search.formatDuration hi) ]
                , Html.span [ Attr.class "mega-scale-lo", Attr.style "top" (String.fromFloat (y lo) ++ "px") ] [ Html.text (Search.formatDuration lo) ]
                ]
        ]


{-| A tick every three hours, labeled with the weekday at midnight.
-}
viewAxis : Plan -> Float -> Html msg
viewAxis p width =
    let
        w =
            columnWidth p

        first =
            p.fromMinutes

        last =
            p.fromMinutes + (p.columns - 1) * p.step

        ticks =
            List.range (ceiling (toFloat first / 180)) (floor (toFloat last / 180))
                |> List.map ((*) 180)

        x absolute =
            toFloat (absolute - first) / toFloat p.step * w + w / 2

        label absolute =
            let
                minuteOfDay =
                    modBy Search.dayLength absolute
            in
            if minuteOfDay == 0 then
                Calendar.formatShort (Calendar.addDays (absolute // Search.dayLength) p.fromDate)
                    |> String.split " "
                    |> List.head
                    |> Maybe.withDefault ""

            else
                hourLabel (minuteOfDay // 60)

        isMidnight absolute =
            modBy Search.dayLength absolute == 0
    in
    Svg.svg [ SvgAttr.width (String.fromFloat width), SvgAttr.height (String.fromFloat axisHeight), SvgAttr.class "mega-axis" ]
        (List.concatMap
            (\t ->
                [ Svg.line
                    [ SvgAttr.x1 (String.fromFloat (x t))
                    , SvgAttr.x2 (String.fromFloat (x t))
                    , SvgAttr.y1
                        (if isMidnight t then
                            "4"

                         else
                            "18"
                        )
                    , SvgAttr.y2 (String.fromFloat axisHeight)
                    , SvgAttr.class
                        (if isMidnight t then
                            "mega-tick mega-tick-day"

                         else
                            "mega-tick"
                        )
                    ]
                    []
                , Svg.text_
                    [ SvgAttr.x (String.fromFloat (x t + 3))
                    , SvgAttr.y "14"
                    , SvgAttr.class
                        (if isMidnight t then
                            "mega-tick-label mega-tick-label-day"

                         else
                            "mega-tick-label"
                        )
                    ]
                    [ Svg.text (label t) ]
                ]
            )
            ticks
        )


hourLabel : Int -> String
hourLabel hour =
    String.fromInt (modBy 12 (hour + 11) + 1)
        ++ (if hour < 12 then
                "a"

            else
                "p"
           )


{-| The ten fastest routes found, as a table: the landscape's best spots in
words.
-}
viewTopTable : Plan -> Dict Cell Outcome -> Html Msg
viewTopTable p results =
    let
        top =
            Dict.toList results
                |> List.sortBy (Tuple.second >> .minutes)
                |> List.take 10

        th text =
            Html.th [ Attr.scope "col" ] [ Html.text text ]

        thNum text =
            Html.th [ Attr.scope "col", Attr.class "num" ] [ Html.text text ]
    in
    if List.isEmpty top then
        Html.text ""

    else
        Html.table [ Attr.class "mega-table" ]
            [ Html.caption [] [ Html.text "Fastest routes so far" ]
            , Html.thead [] [ Html.tr [] [ th "Start", th "From", th "Finish", thNum "Time", thNum "Distance", th "" ] ]
            , Html.tbody []
                (List.map
                    (\(( ( col, city ), o ) as entry) ->
                        Html.tr []
                            [ Html.td [] [ Html.text (startText p col) ]
                            , Html.td [] [ Html.text (cityName city) ]
                            , Html.td [] [ Html.text (cityName o.finish) ]
                            , Html.td [ Attr.class "num" ] [ Html.text (Search.formatDuration o.minutes) ]
                            , Html.td [ Attr.class "num" ] [ Html.text (Search.formatMiles o.meters) ]
                            , Html.td [] [ Html.a [ Attr.href (simulatorLink p (Tuple.first entry)), Attr.target "_blank" ] [ Html.text "Open ↗" ] ]
                            ]
                    )
                    top
                )
            ]


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }
