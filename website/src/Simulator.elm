module Simulator exposing (main)

{-| The interactive route simulator on simulator.html, mounted with
`Elm.Simulator.init({ node, flags: today })` (see `init`).

  - The energy function isn't a simple sum of edge weights — it has to walk
    the tour in order, carrying an accumulated clock forward, because
    whether you wait at a restaurant depends on when you arrive (see
    `simulate`).
  - The search's starting seed comes from a user-editable text field (see
    `SetSeedInput`, `parseSeed`), converted to a `Random.Seed` via
    `Random.initialSeed` — deterministic, so the whole search starts
    synchronously in `init`/`startSearch`, with no `Cmd`-driven randomness.

Every McDonald's location in Manhattan (as of the last scrape), named by their real nicknames and
real per-weekday hours, connected by real walking distances in meters — all
generated into `McdData` from the database by
scripts/export_simulator_data.py. This is an open path, not a round
trip: it can start at any location, but must end at "OCCUPY" (160
Broadway). Some locations are open 24 hours; the rest have real weekly
schedules — including days that are fully open, days that close at midnight,
and one or two nights that run past midnight into the next calendar day —
and arriving while closed means waiting for the next opening, which the UI's
start date picker determines (see `weekdayName`). Travel time between stops
is the raw distance converted at a pace the UI also asks for, in
minutes/mile (see `travelTime`).
-}

import Array exposing (Array)
import Browser
import Browser.Events
import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Events
import Html.Lazy
import List.Extra
import McdData exposing (City, cities, distanceMeters)
import MctrotMapData
import Random
import SimulatedAnnealing exposing (Config, State)
import SimulatedAnnealing.Schedule as Schedule
import Svg exposing (Svg)
import Svg.Attributes as SvgAttr



-- PROBLEM DEFINITION


metersPerMile : Float
metersPerMile =
    1609.344


{-| Parses the value of the pace `<input type="number">` (minutes per
mile). Falls back to a brisk-walk pace if the field is ever empty,
non-numeric, or non-positive.
-}
parseMinutesPerMile : String -> Float
parseMinutesPerMile raw =
    case String.toFloat raw of
        Just minutesPerMile ->
            if minutesPerMile > 0 then
                minutesPerMile

            else
                defaultMinutesPerMile

        Nothing ->
            defaultMinutesPerMile


defaultMinutesPerMile : Float
defaultMinutesPerMile =
    24


{-| Parses the value of the stop time `<input type="number">` (whole
minutes spent at each location). Falls back to the default if the field is
ever empty, non-numeric, or negative.
-}
parseStopMinutes : String -> Int
parseStopMinutes raw =
    case String.toInt raw of
        Just minutes ->
            if minutes >= 0 then
                minutes

            else
                defaultStopMinutes

        Nothing ->
            defaultStopMinutes


defaultStopMinutes : Int
defaultStopMinutes =
    5


metersPerMinuteFromPace : Float -> Float
metersPerMinuteFromPace minutesPerMile =
    metersPerMile / minutesPerMile


{-| `metersPerMinute` is derived from the pace picker (minutes/mile) rather
than passed as a speed directly, since "minutes per mile" is what the UI
asks for — this is the one place that conversion happens, everything else
just uses the resulting rate.
-}
travelTime : Float -> Int -> Int -> Int
travelTime metersPerMinute from to =
    distanceMeters
        |> Array.get from
        |> Maybe.andThen (Array.get to)
        |> Maybe.withDefault 0
        |> toFloat
        |> (\meters -> meters / metersPerMinute)
        |> round


{-| The route must finish here: "OCCUPY", 160 Broadway. Looked up by name
rather than hardcoded so it stays correct if `cities` is ever reordered.
-}
endIndex : Int
endIndex =
    cities
        |> Array.toIndexedList
        |> List.filter (\( _, city ) -> city.name == "OCCUPY")
        |> List.head
        |> Maybe.map Tuple.first
        |> Maybe.withDefault 0


{-| Parses the value of an `<input type="time">` ("HH:MM") into minutes
since midnight. Falls back to 6:00 AM if the field is ever empty or
malformed.
-}
parseStartMinutes : String -> Int
parseStartMinutes timeOfDay =
    case String.split ":" timeOfDay |> List.map String.toInt of
        [ Just hh, Just mm ] ->
            hh * 60 + mm

        _ ->
            6 * 60


{-| Parses the value of the seed text input into the `Int` `Random.initialSeed`
needs. Falls back to 0 if the field is ever empty or non-numeric.
-}
parseSeed : String -> Int
parseSeed raw =
    String.toInt raw |> Maybe.withDefault 0


{-| Sakamoto's algorithm for the day of the week of a Gregorian date:
0 = Sunday .. 6 = Saturday.
-}
sakamotoWeekday : Int -> Int -> Int -> Int
sakamotoWeekday year month day =
    let
        offsets =
            [ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 ]

        y =
            if month < 3 then
                year - 1

            else
                year

        offset =
            List.Extra.getAt (month - 1) offsets |> Maybe.withDefault 0
    in
    modBy 7 (y + y // 4 - y // 100 + y // 400 + offset + day)


parseDate : String -> Maybe ( Int, Int, Int )
parseDate isoDate =
    case String.split "-" isoDate |> List.map String.toInt of
        [ Just year, Just month, Just day ] ->
            Just ( year, month, day )

        _ ->
            Nothing


{-| Turns the value of an `<input type="date">` ("YYYY-MM-DD") into a
weekday name, for display next to the picker.
-}
weekdayName : String -> Maybe String
weekdayName isoDate =
    parseDate isoDate
        |> Maybe.andThen
            (\( year, month, day ) ->
                [ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" ]
                    |> List.Extra.getAt (sakamotoWeekday year month day)
            )


{-| Same date, but as a Monday-indexed 0..6 — matching the order each
city's weekly hours are listed in (Mon..Sun) — for feeding into
`weekMinute`. Falls back to Monday if the date is invalid.
-}
mondayIndexedWeekday : String -> Int
mondayIndexedWeekday isoDate =
    parseDate isoDate
        |> Maybe.map (\( year, month, day ) -> modBy 7 (sakamotoWeekday year month day + 6))
        |> Maybe.withDefault 0


dayLength : Int
dayLength =
    24 * 60


weekLength : Int
weekLength =
    7 * dayLength


{-| The conditions a run is pinned to: which day of the week it begins on
(Monday-indexed, 0..6), what time of day, how fast travel between stops
is, and how long is spent at each stop. Bundled together because they're
all snapshotted at the same moment — when a search (re)starts — so the
energy function stays fixed for the life of that search.
-}
type alias StartTime =
    { weekday : Int
    , minutes : Int
    , metersPerMinute : Float
    , stopMinutes : Int
    }


{-| `arrival` is minutes elapsed since the tour began; this converts that
into "minutes since Monday 00:00" in the repeating weekly cycle each city's
`openWindows`/`closedWindows` are expressed in.
-}
weekMinute : StartTime -> Int -> Int
weekMinute startTime arrival =
    modBy weekLength (startTime.weekday * dayLength + startTime.minutes + arrival)


{-| Minutes to wait if you arrive at a city with the given open windows
(minutes-since-Monday-00:00) at `arrival` minutes into the tour. 0 if
already open. A city with no closed windows (open 24/7) is always open.
-}
waitForCity : List ( Int, Int ) -> StartTime -> Int -> Int
waitForCity openWindows startTime arrival =
    let
        wm =
            weekMinute startTime arrival

        isOpenNow =
            List.any (\( s, e ) -> wm >= s && wm < e) openWindows
    in
    if isOpenNow then
        0

    else
        openWindows
            |> List.map (\( s, _ ) -> modBy weekLength (s - wm))
            |> List.minimum
            |> Maybe.withDefault 0



-- SOLUTION: a tour is a permutation of every non-finish city index,
-- visited in order. The first stop is wherever the route starts; `simulate`
-- appends the fixed finish (`endIndex`) as the last stop.


type alias Tour =
    List Int


{-| `departure` is `arrival + wait + stopMinutes`: the stop starts once the
restaurant is open.
-}
type alias Visit =
    { cityIndex : Int
    , arrival : Int
    , wait : Int
    , departure : Int
    }


{-| Walk the tour in order starting at `startTime` from wherever the tour
begins, carrying the clock forward leg by leg, then travel on to the fixed
finish (`endIndex`). This is why the energy function can't just sum edge
weights: whether (and how long) you wait at a city depends on the
accumulated time — and now the day of the week — when you get there, not
on the edge alone. Every stop, including the first and the finish, adds
`startTime.stopMinutes`.
-}
simulate : StartTime -> Tour -> List Visit
simulate startTime tour =
    case tour of
        [] ->
            []

        first :: rest ->
            let
                firstWait =
                    waitForCity (openWindowsFor first) startTime 0

                firstVisit =
                    { cityIndex = first, arrival = startTime.minutes, wait = firstWait, departure = startTime.minutes + firstWait + startTime.stopMinutes }

                visitCity ( prevCity, clock, visits ) cityIndex =
                    let
                        arrival =
                            clock + travelTime startTime.metersPerMinute prevCity cityIndex

                        wait =
                            waitForCity (openWindowsFor cityIndex) startTime (arrival - startTime.minutes)

                        departure =
                            arrival + wait + startTime.stopMinutes
                    in
                    ( cityIndex, departure, { cityIndex = cityIndex, arrival = arrival, wait = wait, departure = departure } :: visits )

                ( _, _, reversedVisits ) =
                    List.foldl (\c acc -> visitCity acc c) ( first, firstVisit.departure, [] ) (rest ++ [ endIndex ])
            in
            firstVisit :: List.reverse reversedVisits


openWindowsFor : Int -> List ( Int, Int )
openWindowsFor cityIndex =
    Array.get cityIndex cities |> Maybe.map .openWindows |> Maybe.withDefault [ ( 0, weekLength ) ]


totalMinutes : StartTime -> Tour -> Int
totalMinutes startTime tour =
    simulate startTime tour
        |> List.Extra.last
        |> Maybe.map (\v -> v.departure - startTime.minutes)
        |> Maybe.withDefault 0


{-| Road distance for the tour's full route (including its fixed final leg
to `endIndex`), in meters — unlike `totalMinutes`, this doesn't depend on
pace or waiting, so it's the same regardless of the run's start settings.
-}
totalDistanceMeters : Tour -> Int
totalDistanceMeters tour =
    let
        stops =
            tour ++ [ endIndex ]
    in
    List.map2 distanceBetween stops (List.drop 1 stops) |> List.sum


{-| Reverse a random contiguous segment of the visiting order — a 2-opt move
over the stops before the fixed final one.
-}
twoOptNeighbor : Tour -> Random.Generator Tour
twoOptNeighbor tour =
    let
        n =
            List.length tour
    in
    Random.pair (Random.int 0 (n - 1)) (Random.int 0 (n - 1))
        |> Random.map
            (\( i, j ) ->
                let
                    lo =
                        min i j

                    hi =
                        max i j
                in
                if lo == hi then
                    tour

                else
                    let
                        ( before, rest ) =
                            List.Extra.splitAt lo tour

                        ( middle, after ) =
                            List.Extra.splitAt (hi - lo + 1) rest
                    in
                    before ++ List.reverse middle ++ after
            )


config : StartTime -> Config Tour
config startTime =
    { energy = toFloat << totalMinutes startTime
    , neighbor = twoOptNeighbor
    , temperature = Schedule.exponential { initial = 400, alpha = 0.99995 }
    , stoppingTemperature = 0.05
    }


initialTour : Tour
initialTour =
    List.range 0 (Array.length cities - 1)
        |> List.filter (\i -> i /= endIndex)



-- MODEL


type alias Model =
    { saState : State Tour
    , running : Bool
    , stepsPerFrame : Int
    , startDate : String
    , startTimeOfDay : String
    , speedInput : String
    , stopInput : String
    , seedInput : String
    , activeStart : StartTime
    , mapVisible : Bool
    , tab : Tab
    }


type Tab
    = MapTab
    | ScheduleTab


type Msg
    = Tick
    | ToggleRunning
    | Restart
    | SetStartDate String
    | SetStartTimeOfDay String
    | SetSpeedInput String
    | SetStopInput String
    | SetSeedInput String
    | ToggleMapVisible
    | SelectTab Tab


{-| (Re)starts the search from `initialTour`, snapshotting `activeStart` (see
`viewRunSettings`) and deriving the seed from `seedInput` via
`Random.initialSeed` — deterministic, so no `Cmd` round trip is needed the
way a truly random seed would require.
-}
startSearch : Model -> Model
startSearch model =
    let
        activeStart =
            { weekday = mondayIndexedWeekday model.startDate
            , minutes = parseStartMinutes model.startTimeOfDay
            , metersPerMinute = metersPerMinuteFromPace (parseMinutesPerMile model.speedInput)
            , stopMinutes = parseStopMinutes model.stopInput
            }
    in
    { model
        | saState = SimulatedAnnealing.init (config activeStart) (Random.initialSeed (parseSeed model.seedInput)) initialTour
        , running = True
        , activeStart = activeStart
    }


{-| `today` is the visitor's local date as `YYYY-MM-DD`, passed in as a flag
by simulator.html, so the first run starts on the day they're looking at it.
-}
init : String -> ( Model, Cmd Msg )
init today =
    let
        speedInput =
            String.fromFloat defaultMinutesPerMile

        stopInput =
            String.fromInt defaultStopMinutes

        seedInput =
            "1"

        startDate =
            today

        startTimeOfDay =
            "06:00"

        activeStart =
            { weekday = mondayIndexedWeekday startDate
            , minutes = parseStartMinutes startTimeOfDay
            , metersPerMinute = metersPerMinuteFromPace (parseMinutesPerMile speedInput)
            , stopMinutes = parseStopMinutes stopInput
            }
    in
    ( { saState = SimulatedAnnealing.init (config activeStart) (Random.initialSeed (parseSeed seedInput)) initialTour
      , running = True
      , stepsPerFrame = 1000
      , startDate = startDate
      , startTimeOfDay = startTimeOfDay
      , speedInput = speedInput
      , stopInput = stopInput
      , seedInput = seedInput
      , activeStart = activeStart
      , mapVisible = True
      , tab = MapTab
      }
    , Cmd.none
    )



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Tick ->
            ( { model | saState = SimulatedAnnealing.stepN (config model.activeStart) model.stepsPerFrame model.saState }
            , Cmd.none
            )

        ToggleRunning ->
            ( { model | running = not model.running }, Cmd.none )

        Restart ->
            ( startSearch model, Cmd.none )

        SetStartDate date ->
            ( { model | startDate = date }, Cmd.none )

        SetStartTimeOfDay timeOfDay ->
            ( { model | startTimeOfDay = timeOfDay }, Cmd.none )

        SetSpeedInput speed ->
            ( { model | speedInput = speed }, Cmd.none )

        SetStopInput stop ->
            ( { model | stopInput = stop }, Cmd.none )

        SetSeedInput seed ->
            ( { model | seedInput = seed }, Cmd.none )

        ToggleMapVisible ->
            ( { model | mapVisible = not model.mapVisible }, Cmd.none )

        SelectTab tab ->
            ( { model | tab = tab }, Cmd.none )



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    if model.running && not (SimulatedAnnealing.isDone (config model.activeStart) model.saState) then
        Browser.Events.onAnimationFrame (\_ -> Tick)

    else
        Sub.none



-- VIEW


timelineWidth : Float
timelineWidth =
    760


rowHeight : Float
rowHeight =
    34


view : Model -> Html Msg
view model =
    let
        tour =
            SimulatedAnnealing.current model.saState

        visits =
            simulate model.activeStart tour

        done =
            SimulatedAnnealing.isDone (config model.activeStart) model.saState

        viewMax =
            max 600 (((totalMinutes model.activeStart tour // 60) + 1) * 60)
    in
    Html.div [ Attr.style "font-family" "sans-serif", Attr.style "max-width" "1100px" ]
        [ viewRunSettings model
        , box "Controls"
            [ Html.button [ Events.onClick ToggleRunning, Attr.disabled done ]
                [ Html.text
                    (if done then
                        "Done"

                     else if model.running then
                        "Pause"

                     else
                        "Resume"
                    )
                ]
            , Html.button [ Events.onClick Restart ] [ Html.text "Restart" ]
            , Html.button [ Events.onClick ToggleMapVisible ]
                [ Html.text
                    (if model.mapVisible then
                        "Hide map (faster)"

                     else
                        "Show map"
                    )
                ]
            ]
        , viewTabs model.tab
            (case model.tab of
                MapTab ->
                    if model.mapVisible then
                        viewMap tour

                    else
                        Html.p [ Attr.style "color" "#666", Attr.style "margin" "0" ] [ Html.text "Map hidden." ]

                ScheduleTab ->
                    Html.div []
                        [ Html.p [ Attr.style "color" "#666", Attr.style "font-size" "0.85rem", Attr.style "margin" "0 0 0.5rem 0" ]
                            [ Html.text "Pink bands are hours a restaurant is closed. Blue bars are time spent at a restaurant. Orange bars also include waiting for it to open." ]
                        , Svg.svg
                            [ SvgAttr.width (String.fromFloat timelineWidth)
                            , SvgAttr.height (String.fromFloat (rowHeight * toFloat (List.length visits) + 10))
                            ]
                            (List.indexedMap (viewRow model.activeStart viewMax) visits |> List.concat)
                        ]
            )
        , Html.div [ Attr.style "margin-top" "0.5rem", Attr.style "display" "flex", Attr.style "gap" "1.5rem" ]
            [ readout "Iteration" (String.fromInt (SimulatedAnnealing.iteration model.saState))
            , readout "Temperature" (String.fromInt (round (SimulatedAnnealing.temperature (config model.activeStart) model.saState)))
            , readout "Current route time" (formatDuration (round (SimulatedAnnealing.currentEnergy model.saState)))
            , readout "Best route time" (formatDuration (round (SimulatedAnnealing.bestEnergy model.saState)))
            , readout "Current distance" (formatMiles (totalDistanceMeters tour))
            , readout "Best distance" (formatMiles (totalDistanceMeters (SimulatedAnnealing.best model.saState)))
            ]
        , box "Output"
            -- Disabled until there's a computed route to act on.
            [ Html.button [ Attr.disabled True ] [ Html.text "Print" ]
            , Html.button [ Attr.disabled True ] [ Html.text "Download GPX" ]
            , Html.details [ Attr.style "flex-basis" "100%" ]
                [ Html.summary [ Attr.style "cursor" "pointer", Attr.style "color" "#666" ]
                    [ Html.text "Distance matrix (meters)" ]
                , viewCostMatrix
                ]
            ]
        ]


{-| A titled group: a `<fieldset>` whose `<legend>` names it.
-}
box : String -> List (Html msg) -> Html msg
box title children =
    Html.fieldset
        [ Attr.style "border" "1px solid #999"
        , Attr.style "margin" "0.75rem 0"
        , Attr.style "padding" "0.75rem"
        , Attr.style "display" "flex"
        , Attr.style "flex-wrap" "wrap"
        , Attr.style "gap" "0.5rem 1rem"
        , Attr.style "align-items" "flex-end"
        ]
        (Html.legend [ Attr.style "font-weight" "bold", Attr.style "padding" "0 0.25rem" ] [ Html.text title ]
            :: children
        )


tabLabel : Tab -> String
tabLabel tab =
    case tab of
        MapTab ->
            "Map"

        ScheduleTab ->
            "Schedule"


tabId : Tab -> String
tabId tab =
    "simulator-tab-" ++ String.toLower (tabLabel tab)


{-| One bordered rectangle with Map/Schedule tabs along its top edge; only
the selected tab's panel is rendered, so the hidden one costs nothing per
frame.
-}
viewTabs : Tab -> Html Msg -> Html Msg
viewTabs selected panel =
    let
        viewTab tab =
            let
                isSelected =
                    tab == selected
            in
            Html.button
                [ Attr.attribute "role" "tab"
                , Attr.id (tabId tab)
                , Attr.attribute "aria-selected"
                    (if isSelected then
                        "true"

                     else
                        "false"
                    )
                , Attr.attribute "aria-controls" "simulator-tabpanel"
                , Events.onClick (SelectTab tab)
                , Attr.style "font" "inherit"
                , Attr.style "padding" "0.4rem 1rem"
                , Attr.style "margin-bottom" "-1px"
                , Attr.style "border" "1px solid #999"
                , Attr.style "border-bottom-color"
                    (if isSelected then
                        "#fff"

                     else
                        "#999"
                    )
                , Attr.style "background"
                    (if isSelected then
                        "#fff"

                     else
                        "#eee"
                    )
                , Attr.style "font-weight"
                    (if isSelected then
                        "bold"

                     else
                        "normal"
                    )
                , Attr.style "cursor" "pointer"
                ]
                [ Html.text (tabLabel tab) ]
    in
    Html.div [ Attr.style "margin" "0.75rem 0" ]
        [ Html.div [ Attr.attribute "role" "tablist", Attr.style "display" "flex", Attr.style "gap" "0.25rem", Attr.style "padding-left" "0.5rem" ]
            (List.map viewTab [ MapTab, ScheduleTab ])
        , Html.div
            [ Attr.attribute "role" "tabpanel"
            , Attr.id "simulator-tabpanel"
            , Attr.attribute "aria-labelledby" (tabId selected)
            , Attr.style "border" "1px solid #999"
            , Attr.style "background" "#fff"
            , Attr.style "padding" "0.75rem"
            ]
            [ panel ]
        ]


mapDisplayWidth : Float
mapDisplayWidth =
    300


mapDisplayHeight : Float
mapDisplayHeight =
    -- Matches data/mctrot_map.svg's viewBox aspect ratio (~1 : 3.64) at mapDisplayWidth.
    1093


{-| One space-separated `lX-lY` token per leg of the tour (the open path,
plus its fixed final leg to `endIndex`), where X and Y are real `mcd_id`s
(see `MctrotMapData.mcdIds`) in ascending order — matching the class-token
convention already baked into `MctrotMapData.routeEdges`. Setting this as an
ancestor `data-active` attribute is what lets `css/mctrot-map.css` highlight
exactly the streets the current tour uses, without Elm ever touching the
(lazy, otherwise-static) SVG subtree itself.
-}
tourEdgeTokens : Tour -> String
tourEdgeTokens tour =
    let
        stops =
            tour ++ [ endIndex ]
    in
    List.map2 pairToken stops (List.drop 1 stops)
        |> String.join " "


pairToken : Int -> Int -> String
pairToken cityIndexA cityIndexB =
    let
        mcdIdFor cityIndex =
            Array.get cityIndex MctrotMapData.mcdIds |> Maybe.withDefault 0

        a =
            mcdIdFor cityIndexA

        b =
            mcdIdFor cityIndexB
    in
    "l" ++ String.fromInt (min a b) ++ "-l" ++ String.fromInt (max a b)


{-| The borough silhouette, all real-street route segments, and every
location dot — built once and never touched again. `viewMap` wraps this in
`Html.Lazy.lazy` so Elm's virtual DOM skips diffing it on every animation
frame; only the wrapping `data-active` attribute actually changes per tick.
-}
viewMapStatic : () -> Html msg
viewMapStatic () =
    Svg.svg
        [ SvgAttr.viewBox MctrotMapData.mapViewBox
        , SvgAttr.width (String.fromFloat mapDisplayWidth)
        , SvgAttr.height (String.fromFloat mapDisplayHeight)
        ]
        [ Svg.path [ SvgAttr.class "borough", SvgAttr.d MctrotMapData.boroughPath ] []
        , Svg.g []
            (MctrotMapData.routeEdges
                |> List.map (\edge -> Svg.path [ SvgAttr.class edge.classes, SvgAttr.d edge.d ] [])
            )
        , Svg.g []
            (MctrotMapData.locationCoords
                |> Array.toList
                |> List.map
                    (\( x, y ) ->
                        Svg.circle
                            [ SvgAttr.class "location"
                            , SvgAttr.cx (String.fromFloat x)
                            , SvgAttr.cy (String.fromFloat y)
                            , SvgAttr.r "150"
                            ]
                            []
                    )
            )
        ]


viewMap : Tour -> Html msg
viewMap tour =
    Html.div [ Attr.attribute "data-active" (tourEdgeTokens tour) ]
        [ Html.Lazy.lazy viewMapStatic () ]


{-| Lets you pick the conditions the next run starts under: which day of
the week (that matters now, since about a fifth of the cities have real
hours that vary by weekday), what time, and how fast travel between stops
is (as a pace in minutes/mile — the units delivery routing usually gets
quoted in — converted to meters/minute for `travelTime`), and how many
minutes are spent at each stop (see `simulate`). Editing these
fields only takes effect the next time the search (re)starts —
`activeStart` is snapshotted at that point, so nudging any of them mid-run
can't shift the energy landscape out from under an in-progress search.
-}
viewRunSettings : Model -> Html Msg
viewRunSettings model =
    box "Parameters"
        [ Html.label []
            [ Html.div [ Attr.style "font-size" "0.75rem", Attr.style "color" "#666" ] [ Html.text "Start date" ]
            , Html.input
                [ Attr.type_ "date"
                , Attr.value model.startDate
                , Events.onInput SetStartDate
                ]
                []
            ]
        , Html.label []
            [ Html.div [ Attr.style "font-size" "0.75rem", Attr.style "color" "#666" ] [ Html.text "Start time" ]
            , Html.input
                [ Attr.type_ "time"
                , Attr.value model.startTimeOfDay
                , Events.onInput SetStartTimeOfDay
                ]
                []
            ]
        , Html.label []
            [ Html.div [ Attr.style "font-size" "0.75rem", Attr.style "color" "#666" ] [ Html.text "Pace (min/mile)" ]
            , Html.input
                [ Attr.type_ "number"
                , Attr.step "0.5"
                , Attr.min "0.5"
                , Attr.value model.speedInput
                , Events.onInput SetSpeedInput
                ]
                []
            ]
        , Html.label []
            [ Html.div [ Attr.style "font-size" "0.75rem", Attr.style "color" "#666" ] [ Html.text "Location stop time (minutes)" ]
            , Html.input
                [ Attr.type_ "number"
                , Attr.step "1"
                , Attr.min "0"
                , Attr.value model.stopInput
                , Events.onInput SetStopInput
                ]
                []
            ]
        , Html.label []
            [ Html.div [ Attr.style "font-size" "0.75rem", Attr.style "color" "#666" ] [ Html.text "Seed" ]
            , Html.input
                [ Attr.type_ "text"
                , Attr.value model.seedInput
                , Events.onInput SetSeedInput
                ]
                []
            ]
        , Html.div [ Attr.style "font-size" "0.8rem", Attr.style "color" "#666" ]
            [ Html.text
                (case weekdayName model.startDate of
                    Just day ->
                        "Starts " ++ day ++ " (changes apply on restart)"

                    Nothing ->
                        "Pick a valid date"
                )
            ]
        ]


readout : String -> String -> Html msg
readout label value =
    Html.div []
        [ Html.div [ Attr.style "font-size" "0.75rem", Attr.style "color" "#666" ] [ Html.text label ]
        , Html.div [ Attr.style "font-variant-numeric" "tabular-nums" ] [ Html.text value ]
        ]


xScale : Int -> Float -> Float
xScale viewMax elapsedMinutes =
    elapsedMinutes * (timelineWidth / toFloat viewMax)


viewRow : StartTime -> Int -> Int -> Visit -> List (Svg msg)
viewRow startTime viewMax rowIndex visit =
    let
        y =
            toFloat rowIndex * rowHeight

        city =
            Array.get visit.cityIndex cities |> Maybe.withDefault (City "?" [ ( 0, weekLength ) ] [])

        arrivalElapsed =
            toFloat (visit.arrival - startTime.minutes)

        departureElapsed =
            toFloat (visit.departure - startTime.minutes)

        label =
            city.name
                ++ " — arr "
                ++ formatClock visit.arrival
                ++ (if visit.wait > 0 then
                        " (waited " ++ formatDuration visit.wait ++ ")"

                    else
                        ""
                   )
    in
    [ Svg.rect
        [ SvgAttr.x "0"
        , SvgAttr.y (String.fromFloat y)
        , SvgAttr.width (String.fromFloat timelineWidth)
        , SvgAttr.height (String.fromFloat (rowHeight - 4))
        , SvgAttr.fill "#fff"
        , SvgAttr.stroke "#eee"
        ]
        []
    ]
        ++ (if not (List.isEmpty city.closedWindows) then
                closedBandsElapsed city.closedWindows startTime viewMax
                    |> List.map
                        (\( s, e ) ->
                            Svg.rect
                                [ SvgAttr.x (String.fromFloat (xScale viewMax (toFloat s)))
                                , SvgAttr.y (String.fromFloat y)
                                , SvgAttr.width (String.fromFloat (xScale viewMax (toFloat (e - s))))
                                , SvgAttr.height (String.fromFloat (rowHeight - 4))
                                , SvgAttr.fill "#fbdcdc"
                                ]
                                []
                        )

            else
                []
           )
        ++ [ Svg.rect
                [ SvgAttr.x (String.fromFloat (xScale viewMax arrivalElapsed))
                , SvgAttr.y (String.fromFloat (y + 6))
                , SvgAttr.width (String.fromFloat (max 2 (xScale viewMax (departureElapsed - arrivalElapsed))))
                , SvgAttr.height (String.fromFloat (rowHeight - 16))
                , SvgAttr.fill
                    (if visit.wait > 0 then
                        "#e8871e"

                     else
                        "#1f6feb"
                    )
                ]
                []
           , Svg.text_
                [ SvgAttr.x "4"
                , SvgAttr.y (String.fromFloat (y + rowHeight - 8))
                , SvgAttr.fontSize "11"
                , SvgAttr.fill "#333"
                ]
                [ Svg.text label ]
           ]


{-| A city's `closedWindows` (minutes-since-Monday-00:00, one repeating
week) converted to minutes-elapsed-since-the-tour-started, tiled across as
many weeks as the visible timeline (`viewMax`) spans, and clipped to
`[0, viewMax]`.
-}
closedBandsElapsed : List ( Int, Int ) -> StartTime -> Int -> List ( Int, Int )
closedBandsElapsed closedInWeek startTime viewMax =
    let
        weekOffset =
            startTime.weekday * dayLength + startTime.minutes

        maxK =
            (viewMax // weekLength) + 2
    in
    List.range 0 maxK
        |> List.concatMap
            (\k ->
                closedInWeek
                    |> List.map (\( s, e ) -> ( s - weekOffset + k * weekLength, e - weekOffset + k * weekLength ))
            )
        |> List.filterMap
            (\( s, e ) ->
                if e < 0 || s > viewMax then
                    Nothing

                else
                    Just ( max 0 s, min viewMax e )
            )


matrixCell : List (Html.Attribute msg)
matrixCell =
    [ Attr.style "border" "1px solid #ddd"
    , Attr.style "padding" "2px 6px"
    , Attr.style "text-align" "center"
    ]


distanceBetween : Int -> Int -> Int
distanceBetween from to =
    distanceMeters
        |> Array.get from
        |> Maybe.andThen (Array.get to)
        |> Maybe.withDefault 0


viewCostMatrix : Html msg
viewCostMatrix =
    let
        cityList =
            Array.toList cities

        headerRow =
            Html.tr []
                (Html.th matrixCell [] :: List.map (\c -> Html.th matrixCell [ Html.text c.name ]) cityList)

        bodyRow i city =
            Html.tr []
                (Html.th matrixCell [ Html.text city.name ]
                    :: List.indexedMap
                        (\j _ ->
                            Html.td matrixCell
                                [ Html.text
                                    (if i == j then
                                        "—"

                                     else
                                        String.fromInt (distanceBetween i j)
                                    )
                                ]
                        )
                        cityList
                )
    in
    Html.table
        [ Attr.style "border-collapse" "collapse"
        , Attr.style "margin-top" "0.5rem"
        , Attr.style "font-size" "0.8rem"
        , Attr.style "font-variant-numeric" "tabular-nums"
        ]
        (headerRow :: List.indexedMap bodyRow cityList)


formatClock : Int -> String
formatClock absoluteMinutes =
    let
        day =
            absoluteMinutes // dayLength

        clock =
            modBy dayLength absoluteMinutes

        hh =
            clock // 60

        mm =
            modBy 60 clock

        pad n =
            String.padLeft 2 '0' (String.fromInt n)
    in
    "day " ++ String.fromInt day ++ " " ++ pad hh ++ ":" ++ pad mm


formatDuration : Int -> String
formatDuration minutes =
    String.fromInt (minutes // 60) ++ "h " ++ String.fromInt (modBy 60 minutes) ++ "m"


formatMiles : Int -> String
formatMiles meters =
    let
        tenths =
            round (toFloat meters / metersPerMile * 10)
    in
    String.fromInt (tenths // 10) ++ "." ++ String.fromInt (modBy 10 tenths) ++ " mi"


main : Program String Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , subscriptions = subscriptions
        , view = view
        }
