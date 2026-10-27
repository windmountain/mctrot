module Simulator exposing (main)

{-| The interactive route simulator on simulator.html, mounted with
`Elm.Simulator.init({ node, flags: defaultStartDate })` (see `init`).

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
scripts/export_simulator_data.py. This is an open path: the start and
end locations are each either picked in the UI or left "Flexible" for the
search to choose (by default it runs from the northernmost location to the
southernmost; see `stops`). Some locations are open 24 hours; the rest have real weekly
schedules — including days that are fully open, days that close at midnight,
and one or two nights that run past midnight into the next calendar day —
and arriving while closed means waiting for the next opening, which the UI's
start date picker determines (see `mondayIndexedWeekday`). Travel time between stops
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


{-| Every city index, north to south along the street grid
(`MctrotMapData.locationCoords` is already rotated so the grid runs
vertically, with y growing southward). Orders the start/end pickers and
gives their defaults: the northernmost start and the southernmost end.
-}
northToSouth : List Int
northToSouth =
    List.range 0 (Array.length cities - 1)
        |> List.sortBy (\i -> Array.get i MctrotMapData.locationCoords |> Maybe.map Tuple.second |> Maybe.withDefault 0)


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
Monday-indexed 0..6 weekday — matching the order each
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
is, how long is spent at each stop, and which locations (if any) the
route must start and end at (`Nothing` = flexible). Bundled together because they're
all snapshotted at the same moment — when a search (re)starts — so the
energy function stays fixed for the life of that search.
-}
type alias StartTime =
    { weekday : Int
    , minutes : Int
    , metersPerMinute : Float
    , stopMinutes : Int
    , startCity : Maybe Int
    , endCity : Maybe Int
    }


{-| Parses a start/end `<select>` value: a city index, or "" for flexible.
-}
parseCity : String -> Maybe Int
parseCity raw =
    String.toInt raw


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



-- SOLUTION: a tour is a permutation of every city index that isn't a fixed
-- start or end, visited in order; `stops` puts the fixed ones (if any)
-- around it.


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


{-| The full visiting order: the fixed start (if any), the tour, then the
fixed end (if any). If start and end are the same location, it's a round
trip and that location appears at both ends.
-}
stops : StartTime -> Tour -> List Int
stops startTime tour =
    List.filterMap identity [ startTime.startCity ] ++ tour ++ List.filterMap identity [ startTime.endCity ]


{-| Walk the `stops` in order starting at `startTime`, carrying the clock
forward leg by leg. This is why the energy function can't just sum edge
weights: whether (and how long) you wait at a city depends on the
accumulated time — and now the day of the week — when you get there, not
on the edge alone. Every stop, including the first and the finish, adds
`startTime.stopMinutes`.
-}
simulate : StartTime -> Tour -> List Visit
simulate startTime tour =
    case stops startTime tour of
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
                    List.foldl (\c acc -> visitCity acc c) ( first, firstVisit.departure, [] ) rest
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


{-| Road distance for the full route (see `stops`), in meters — unlike
`totalMinutes`, this doesn't depend on pace or waiting.
-}
totalDistanceMeters : StartTime -> Tour -> Int
totalDistanceMeters startTime tour =
    let
        route =
            stops startTime tour
    in
    List.map2 distanceBetween route (List.drop 1 route) |> List.sum


{-| Reverse a random contiguous segment of the visiting order — a 2-opt move
over the stops between any fixed start and end.
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


initialTour : StartTime -> Tour
initialTour startTime =
    List.range 0 (Array.length cities - 1)
        |> List.filter (\i -> Just i /= startTime.startCity && Just i /= startTime.endCity)



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
    , startCityInput : String
    , endCityInput : String
    , activeStart : StartTime
    , tab : Tab
    , mapFit : MapFit
    }


type Tab
    = ScheduleTab
    | MapTab


{-| How the map fills its box: `Normal` keeps its true proportions, `Stretch`
stretches the whole map to the box's width, and `Superstretch` stretches
just the locations and route paths to within `superstretchPadding` of each
side (see `viewMapStatic`).
-}
type MapFit
    = Normal
    | Stretch
    | Superstretch


mapFits : List ( MapFit, String, String )
mapFits =
    [ ( Normal, "normal", "Normal" )
    , ( Stretch, "stretch", "Stretch" )
    , ( Superstretch, "superstretch", "Superstretch" )
    ]


type Msg
    = Tick
    | Start
    | SetStartDate String
    | SetStartTimeOfDay String
    | SetSpeedInput String
    | SetStopInput String
    | SetSeedInput String
    | SetStartCityInput String
    | SetEndCityInput String
    | SelectTab Tab
    | SetMapFit String


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
            , startCity = parseCity model.startCityInput
            , endCity = parseCity model.endCityInput
            }
    in
    { model
        | saState = SimulatedAnnealing.init (config activeStart) (Random.initialSeed (parseSeed model.seedInput)) (initialTour activeStart)
        , running = True
        , activeStart = activeStart
    }


{-| `defaultStartDate` is the next Nov 21 (today or later) in the visitor's
local time, as `YYYY-MM-DD`, passed in as a flag by simulator.html — the
year depends on the visitor's clock, which Elm can't read synchronously.
-}
init : String -> ( Model, Cmd Msg )
init defaultStartDate =
    let
        speedInput =
            String.fromFloat defaultMinutesPerMile

        stopInput =
            String.fromInt defaultStopMinutes

        seedInput =
            "1"

        startDate =
            defaultStartDate

        startTimeOfDay =
            "02:00"

        startCityInput =
            List.head northToSouth |> Maybe.map String.fromInt |> Maybe.withDefault ""

        endCityInput =
            List.Extra.last northToSouth |> Maybe.map String.fromInt |> Maybe.withDefault ""

        activeStart =
            { weekday = mondayIndexedWeekday startDate
            , minutes = parseStartMinutes startTimeOfDay
            , metersPerMinute = metersPerMinuteFromPace (parseMinutesPerMile speedInput)
            , stopMinutes = parseStopMinutes stopInput
            , startCity = parseCity startCityInput
            , endCity = parseCity endCityInput
            }
    in
    ( { saState = SimulatedAnnealing.init (config activeStart) (Random.initialSeed (parseSeed seedInput)) (initialTour activeStart)
      , running = False
      , stepsPerFrame = 1000
      , startDate = startDate
      , startTimeOfDay = startTimeOfDay
      , speedInput = speedInput
      , stopInput = stopInput
      , seedInput = seedInput
      , startCityInput = startCityInput
      , endCityInput = endCityInput
      , activeStart = activeStart
      , tab = ScheduleTab
      , mapFit = Stretch
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

        Start ->
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

        SetStartCityInput city ->
            ( { model | startCityInput = city }, Cmd.none )

        SetEndCityInput city ->
            ( { model | endCityInput = city }, Cmd.none )

        SelectTab tab ->
            ( { model | tab = tab }, Cmd.none )

        SetMapFit value ->
            ( { model
                | mapFit =
                    List.Extra.find (\( _, v, _ ) -> v == value) mapFits
                        |> Maybe.map (\( fit, _, _ ) -> fit)
                        |> Maybe.withDefault model.mapFit
              }
            , Cmd.none
            )



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    if model.running && not (SimulatedAnnealing.isDone (config model.activeStart) model.saState) then
        Browser.Events.onAnimationFrame (\_ -> Tick)

    else
        Sub.none



-- VIEW


{-| Roughly how wide the schedule's timeline column renders. It actually
stretches to fill whatever the location-name column leaves (see
`viewSchedule`), so this only decides how densely `viewTimeAxis` labels
hours.
-}
nominalTimelineWidth : Float
nominalTimelineWidth =
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

        viewMax =
            max 600 (((totalMinutes model.activeStart tour // 60) + 1) * 60)
    in
    Html.div [ Attr.style "font-family" "sans-serif", Attr.style "max-width" "1100px" ]
        [ viewRunSettings model
        , box "Search"
            [ Html.button [ Events.onClick Start ] [ Html.text "Start" ]
            , readout "Iteration" (String.fromInt (SimulatedAnnealing.iteration model.saState))
            , readout "Temperature" (String.fromInt (round (SimulatedAnnealing.temperature (config model.activeStart) model.saState)))
            , readout "Current route time" (formatDuration (round (SimulatedAnnealing.currentEnergy model.saState)))
            , readout "Current distance" (formatMiles (totalDistanceMeters model.activeStart tour))
            ]
        , viewTabs model.tab
            (case model.tab of
                MapTab ->
                    viewMap model.mapFit (stops model.activeStart tour)

                ScheduleTab ->
                    Html.div []
                        [ Html.p [ Attr.style "color" "#666", Attr.style "font-size" "0.85rem", Attr.style "margin" "0 0 0.5rem 0" ]
                            [ Html.text "Pink bands are hours a restaurant is closed. Blue bars are time spent at a restaurant. Orange bars also include waiting for it to open." ]
                        , viewSchedule model.activeStart viewMax visits
                        ]
            )
        , box "Results"
            [ readout "Best route time" (formatDuration (round (SimulatedAnnealing.bestEnergy model.saState)))
            , readout "Best distance" (formatMiles (totalDistanceMeters model.activeStart (SimulatedAnnealing.best model.saState)))
            ]
        , box "Output"
            -- Disabled until there's a computed route to act on.
            [ Html.button [ Attr.disabled True ] [ Html.text "Print" ]
            , Html.button [ Attr.disabled True ] [ Html.text "Download GPX" ]
            , Html.details [ Attr.class "distance-matrix", Attr.style "flex-basis" "100%" ]
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
            (List.map viewTab [ ScheduleTab, MapTab ])
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


{-| One space-separated `lX-lY` token per leg of the route (see `stops`), where X and Y are real `mcd_id`s
(see `MctrotMapData.mcdIds`) in ascending order — matching the class-token
convention already baked into `MctrotMapData.routeEdges`. Setting this as an
ancestor `data-active` attribute is what lets `css/mctrot-map.css` highlight
exactly the streets the current tour uses, without Elm ever touching the
(lazy, otherwise-static) SVG subtree itself.
-}
tourEdgeTokens : List Int -> String
tourEdgeTokens route =
    List.map2 pairToken route (List.drop 1 route)
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


superstretchPadding : String
superstretchPadding =
    "10px"


{-| The viewBox the map's layers share for each `MapFit`: `Superstretch`
narrows it to `MctrotMapData.routeViewBox` and lets the borough spill into
the padding, clipped at the box's edge.
-}
mapViewBoxFor : MapFit -> String
mapViewBoxFor fit =
    if fit == Superstretch then
        MctrotMapData.routeViewBox

    else
        MctrotMapData.mapViewBox


{-| One of the map's stacked layers: an SVG filling the map frame (see
`viewMapFrame`) with the viewBox for `fit`. `Stretch` and `Superstretch`
fill the frame horizontally (`preserveAspectRatio "none"`);
css/mctrot-map.css keeps line widths and the round dots from stretching with
it.
-}
mapLayer : MapFit -> List (Svg msg) -> Html msg
mapLayer fit =
    Svg.svg
        [ SvgAttr.viewBox (mapViewBoxFor fit)
        , SvgAttr.width "100%"
        , SvgAttr.height "100%"
        , SvgAttr.preserveAspectRatio
            (if fit == Normal then
                "xMidYMid meet"

             else
                "none"
            )
        , Attr.style "position" "absolute"
        , Attr.style "inset" "0"
        , Attr.style "overflow" "visible"
        ]


{-| The box the layers stack in: `mapDisplayWidth` wide and centered for
`Normal`, the full width otherwise (less `superstretchPadding` on each side
for `Superstretch`).
-}
viewMapFrame : MapFit -> List (Html msg) -> Html msg
viewMapFrame fit layers =
    Html.div
        [ Attr.style "padding"
            (if fit == Superstretch then
                "0 " ++ superstretchPadding

             else
                "0"
            )
        , Attr.style "overflow" "hidden"
        ]
        [ Html.div
            [ Attr.style "position" "relative"
            , Attr.style "height" (String.fromFloat mapDisplayHeight ++ "px")
            , Attr.style "width"
                (if fit == Normal then
                    String.fromFloat mapDisplayWidth ++ "px"

                 else
                    "auto"
                )
            , Attr.style "margin" "0 auto"
            ]
            layers
        ]


{-| The borough silhouette — built once per `MapFit` and never touched
again. `viewMap` wraps this and the other static layers in `Html.Lazy.lazy` so
Elm's virtual DOM skips diffing them on every animation frame.
-}
viewBoroughLayer : MapFit -> Html msg
viewBoroughLayer fit =
    mapLayer fit [ Svg.path [ SvgAttr.class "borough", SvgAttr.d MctrotMapData.boroughPath ] [] ]


{-| All real-street route segments — built once per `MapFit`; only the
wrapping `data-active` attribute changes per tick (see `tourEdgeTokens`).
-}
viewRouteLayer : MapFit -> Html msg
viewRouteLayer fit =
    mapLayer fit
        (MctrotMapData.routeEdges
            |> List.map (\edge -> Svg.path [ SvgAttr.class edge.classes, SvgAttr.d edge.d ] [])
        )


{-| Every location dot — built once per `MapFit`, on top of everything else.
-}
viewLocationLayer : MapFit -> Html msg
viewLocationLayer fit =
    mapLayer fit
        [ Svg.g []
            (MctrotMapData.locationCoords
                |> Array.toList
                |> List.map
                    (\( x, y ) ->
                        Svg.path
                            [ SvgAttr.class "location"
                            , SvgAttr.d ("M" ++ String.fromFloat x ++ " " ++ String.fromFloat y ++ "h0")
                            ]
                            []
                    )
            )
        ]


{-| Diamonds over the route but under the location dots, at the first and
last of `route` (see `stops`): green for the start, a 2x2 checkered flag for
the finish. They're HTML, positioned by
percentage within the map frame, so they keep their shape however the map
is stretched. For a round trip the flag covers the start.
-}
viewEndpoints : MapFit -> List Int -> Html msg
viewEndpoints fit route =
    let
        viewBox =
            case String.split " " (mapViewBoxFor fit) |> List.filterMap String.toFloat of
                [ x, y, w, h ] ->
                    Just { x = x, y = y, w = w, h = h }

                _ ->
                    Nothing

        diamond background cityIndex =
            case ( viewBox, Array.get cityIndex MctrotMapData.locationCoords ) of
                ( Just vb, Just ( x, y ) ) ->
                    [ Html.div
                        [ Attr.style "position" "absolute"
                        , Attr.style "left" (String.fromFloat ((x - vb.x) / vb.w * 100) ++ "%")
                        , Attr.style "top" (String.fromFloat ((y - vb.y) / vb.h * 100) ++ "%")
                        , Attr.style "width" "14px"
                        , Attr.style "height" "14px"
                        , Attr.style "transform" "translate(-50%, -50%) rotate(45deg)"
                        , Attr.style "background" background
                        , Attr.style "border" "1px solid #fff"
                        ]
                        []
                    ]

                _ ->
                    []

        at background cityIndex =
            Maybe.map (diamond background) cityIndex |> Maybe.withDefault []
    in
    Html.div [ Attr.style "position" "absolute", Attr.style "inset" "0", Attr.style "pointer-events" "none" ]
        (at "#1a9e3a" (List.head route)
            ++ at "conic-gradient(#000 0 25%, #fff 0 50%, #000 0 75%, #fff 0)" (List.Extra.last route)
        )


{-| The map with a `MapFit` dropdown pinned to its top right corner.
-}
viewMap : MapFit -> List Int -> Html Msg
viewMap fit route =
    Html.div [ Attr.style "position" "relative" ]
        [ Html.div [ Attr.attribute "data-active" (tourEdgeTokens route) ]
            [ viewMapFrame fit
                [ Html.Lazy.lazy viewBoroughLayer fit
                , Html.Lazy.lazy viewRouteLayer fit
                , viewEndpoints fit route
                , Html.Lazy.lazy viewLocationLayer fit
                ]
            ]
        , Html.select
            [ Attr.style "position" "absolute"
            , Attr.style "top" "0"
            , Attr.style "right" "0"
            , Attr.attribute "aria-label" "Map fit"
            , Events.onInput SetMapFit
            ]
            (List.map
                (\( f, value, label ) -> Html.option [ Attr.value value, Attr.selected (f == fit) ] [ Html.text label ])
                mapFits
            )
        ]


{-| Lets you pick the conditions the next run starts under: which day of
the week (that matters now, since about a fifth of the cities have real
hours that vary by weekday), what time, and how fast travel between stops
is (as a pace in minutes/mile — the units delivery routing usually gets
quoted in — converted to meters/minute for `travelTime`), and how many
minutes are spent at each stop (see `simulate`), and where the route
starts and ends (see `stops`). Editing these
fields only takes effect the next time the search (re)starts —
`activeStart` is snapshotted at that point, so nudging any of them mid-run
can't shift the energy landscape out from under an in-progress search.
-}
viewRunSettings : Model -> Html Msg
viewRunSettings model =
    box "Parameters"
        [ paramRow
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
            ]
        , paramRow
            [ Html.label []
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
            ]
        , paramRow [ viewCitySelect "Start location" model.startCityInput SetStartCityInput ]
        , paramRow [ viewCitySelect "End location" model.endCityInput SetEndCityInput ]
        , paramRow
            [ Html.label []
                [ Html.div [ Attr.style "font-size" "0.75rem", Attr.style "color" "#666" ] [ Html.text "Seed" ]
                , Html.input
                    [ Attr.type_ "text"
                    , Attr.value model.seedInput
                    , Events.onInput SetSeedInput
                    ]
                    []
                ]
            ]
        ]


{-| One full-width line inside a `box`, so related fields stay together and
each group starts on its own line.
-}
paramRow : List (Html msg) -> Html msg
paramRow =
    Html.div
        [ Attr.style "flex-basis" "100%"
        , Attr.style "display" "flex"
        , Attr.style "flex-wrap" "wrap"
        , Attr.style "gap" "0.5rem 1rem"
        , Attr.style "align-items" "flex-end"
        ]


{-| A start/end location picker: "Flexible" (value "") first, then every
location as "NICKNAME (address)", north to south (see `northToSouth`).
Option values are city indices (see `parseCity`).
-}
viewCitySelect : String -> String -> (String -> Msg) -> Html Msg
viewCitySelect label selectedValue toMsg =
    let
        option value text =
            Html.option [ Attr.value value, Attr.selected (value == selectedValue) ] [ Html.text text ]
    in
    Html.label []
        [ Html.div [ Attr.style "font-size" "0.75rem", Attr.style "color" "#666" ] [ Html.text label ]
        , Html.select [ Events.onInput toMsg ]
            (option "" "Flexible"
                :: (northToSouth
                        |> List.filterMap (\i -> Array.get i cities |> Maybe.map (\city -> option (String.fromInt i) (city.name ++ " (" ++ city.address ++ ")")))
                   )
            )
        ]


readout : String -> String -> Html msg
readout label value =
    Html.div []
        [ Html.div [ Attr.style "font-size" "0.75rem", Attr.style "color" "#666" ] [ Html.text label ]
        , Html.div [ Attr.style "font-variant-numeric" "tabular-nums" ] [ Html.text value ]
        ]


{-| An elapsed time as an SVG x coordinate or width: a percentage of the
timeline, which spans `viewMax` minutes across however wide it renders.
-}
xScale : Int -> Float -> String
xScale viewMax elapsedMinutes =
    String.fromFloat (elapsedMinutes / toFloat viewMax * 100) ++ "%"


{-| A two-column grid: location names down the left (as wide as the longest
one), and the time axis and one timeline row per visit filling the rest.
-}
viewSchedule : StartTime -> Int -> List Visit -> Html msg
viewSchedule startTime viewMax visits =
    Html.div
        [ Attr.style "display" "grid"
        , Attr.style "grid-template-columns" "max-content 1fr"
        , Attr.style "column-gap" "0.5rem"
        , Attr.style "align-items" "center"
        ]
        (Html.div [] []
            :: viewTimeAxis startTime viewMax
            :: List.concatMap (viewRow startTime viewMax) visits
        )


timeAxisHeight : Float
timeAxisHeight =
    26


{-| The schedule's x-axis, drawn as its own row above the visits on the
same `xScale`: a tick every 15 minutes of clock time, taller ticks on the
hour, and hour labels ("8 PM") spaced out to every 2, 3, ... hours when a
long route squeezes them closer than `minLabelSpacing` pixels. Labels too
close to either end to fit are left off.
-}
viewTimeAxis : StartTime -> Int -> Html msg
viewTimeAxis startTime viewMax =
    let
        minLabelSpacing =
            44

        pixelsPerHour =
            60 * nominalTimelineWidth / toFloat viewMax

        labelEveryHours =
            [ 1, 2, 3, 4, 6, 12, 24 ]
                |> List.filter (\hours -> toFloat hours * pixelsPerHour >= minLabelSpacing)
                |> List.head
                |> Maybe.withDefault 24

        baseline =
            timeAxisHeight - 2

        firstQuarter =
            modBy 15 (15 - modBy 15 startTime.minutes)

        tick elapsed =
            let
                clock =
                    modBy dayLength (startTime.minutes + elapsed)

                isHour =
                    modBy 60 clock == 0

                x =
                    toFloat elapsed * nominalTimelineWidth / toFloat viewMax

                tickLine =
                    Svg.line
                        [ SvgAttr.x1 (xScale viewMax (toFloat elapsed))
                        , SvgAttr.x2 (xScale viewMax (toFloat elapsed))
                        , SvgAttr.y1 (String.fromFloat baseline)
                        , SvgAttr.y2
                            (String.fromFloat
                                (if isHour then
                                    baseline - 8

                                 else
                                    baseline - 4
                                )
                            )
                        , SvgAttr.stroke "#999"
                        ]
                        []

                fitsLabel =
                    x >= 16 && x <= nominalTimelineWidth - 16
            in
            if isHour && modBy labelEveryHours (clock // 60) == 0 && fitsLabel then
                [ tickLine
                , Svg.text_
                    [ SvgAttr.x (xScale viewMax (toFloat elapsed))
                    , SvgAttr.y (String.fromFloat (baseline - 11))
                    , SvgAttr.textAnchor "middle"
                    , SvgAttr.fontSize "11"
                    , SvgAttr.fill "#333"
                    ]
                    [ Svg.text (formatHour (clock // 60)) ]
                ]

            else
                [ tickLine ]
    in
    Svg.svg
        [ SvgAttr.width "100%"
        , SvgAttr.height (String.fromFloat timeAxisHeight)
        , Attr.style "display" "block"
        ]
        (Svg.line
            [ SvgAttr.x1 "0"
            , SvgAttr.x2 "100%"
            , SvgAttr.y1 (String.fromFloat baseline)
            , SvgAttr.y2 (String.fromFloat baseline)
            , SvgAttr.stroke "#999"
            ]
            []
            :: (List.range 0 ((viewMax - firstQuarter) // 15)
                    |> List.concatMap (\i -> tick (firstQuarter + i * 15))
               )
        )


{-| An hour of the day (0-23) on a 12-hour clock: "12 AM", "8 PM".
-}
formatHour : Int -> String
formatHour hour =
    let
        twelveHour =
            if modBy 12 hour == 0 then
                12

            else
                modBy 12 hour
    in
    String.fromInt twelveHour
        ++ (if hour < 12 then
                " AM"

            else
                " PM"
           )


{-| One visit's two grid cells (see `viewSchedule`): its location name, and
its timeline — closed hours in pink, then the time spent there (orange if
it included waiting for it to open).
-}
viewRow : StartTime -> Int -> Visit -> List (Html msg)
viewRow startTime viewMax visit =
    let
        city =
            Array.get visit.cityIndex cities |> Maybe.withDefault (City "?" "" [ ( 0, weekLength ) ] [])

        arrivalElapsed =
            toFloat (visit.arrival - startTime.minutes)

        departureElapsed =
            toFloat (visit.departure - startTime.minutes)

        label =
            city.name
                ++ (if visit.wait > 0 then
                        " (waited " ++ formatDuration visit.wait ++ ")"

                    else
                        ""
                   )

        barHeight =
            rowHeight - 4

        visitColor =
            if visit.wait > 0 then
                "#e8871e"

            else
                "#1f6feb"
    in
    [ Html.div [ Attr.style "font-size" "11px", Attr.style "color" "#333", Attr.style "white-space" "nowrap" ]
        [ Html.text label ]
    , Svg.svg
        [ SvgAttr.width "100%"
        , SvgAttr.height (String.fromFloat rowHeight)
        , Attr.style "display" "block"
        ]
        (Svg.rect
            [ SvgAttr.x "0"
            , SvgAttr.y "0"
            , SvgAttr.width "100%"
            , SvgAttr.height (String.fromFloat barHeight)
            , SvgAttr.fill "#fff"
            , SvgAttr.stroke "#eee"
            ]
            []
            :: (closedBandsElapsed city.closedWindows startTime viewMax
                    |> List.map
                        (\( s, e ) ->
                            Svg.rect
                                [ SvgAttr.x (xScale viewMax (toFloat s))
                                , SvgAttr.y "0"
                                , SvgAttr.width (xScale viewMax (toFloat (e - s)))
                                , SvgAttr.height (String.fromFloat barHeight)
                                , SvgAttr.fill "#fbdcdc"
                                ]
                                []
                        )
               )
            ++ [ Svg.rect
                    [ SvgAttr.x (xScale viewMax arrivalElapsed)
                    , SvgAttr.y "6"
                    , SvgAttr.width (xScale viewMax (departureElapsed - arrivalElapsed))
                    , SvgAttr.height (String.fromFloat (rowHeight - 16))
                    , SvgAttr.fill visitColor

                    -- A same-colored 1px outline keeps a very short visit at least 2px wide.
                    , SvgAttr.stroke visitColor
                    ]
                    []
               ]
        )
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
