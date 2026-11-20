port module Live exposing (main)

{-| mctrot.nyc/live: where I am during a McTrot attempt.

Polls the recorder's `GET /live` (recorder/api/src/live.ts; contract in
recorder/api/live.schema.json) every 15 seconds.

One program for five addresses, routed here (Netlify serves live.html for
all of them; website/_redirects):

  - /live: everything on one page, as it has been
  - /live/map, /live/blog, /live/timeline, /live/stats: one view each,
    taking over the page

All five share the title, the radio and the tab switcher.
Switching tabs doesn't reload the page, so the radio keeps playing.

Elm runs in its own element (Browser.element), not over the whole page
(Browser.application): browser extensions add things to <body>, and an
application, which owns the body, crashes when they do. So the address
is handled here through two ports and a few lines in live.html:
`navigate` (pushState) and `pathChanged` (Back and Forward).

-}

import Browser
import Browser.Dom
import Browser.Events
import Burndown
import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Events
import Html.Keyed
import Http
import Json.Decode as Decode exposing (Decoder)
import Dict
import Guests
import LiveMapData
import NewYorkTime
import Process
import Projection
import Radio
import SnapToStreets
import Simplify
import SolarTime
import Status
import Svg exposing (Svg)
import Svg.Attributes as SvgAttr
import Svg.Events
import Svg.Lazy
import Task
import Time
import Url exposing (Url)
import Url.Parser as Parser exposing ((</>))


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }


{-| Show this path in the address bar (a new history entry), and set the
page's title.
-}
port navigate : { path : String, title : String } -> Cmd msg


{-| The page's title, for the first view.
-}
port setTitle : String -> Cmd msg


{-| The path after Back or Forward.
-}
port pathChanged : (String -> msg) -> Sub msg



-- ROUTES


type Route
    = Overview
    | MapTab
    | BlogTab
    | TimelineTab
    | StatsTab


{-| /live (or /live.html, as a plain file server has it) is the overview;
anything unknown under /live shows it too.
-}
routeFromUrl : Url -> Route
routeFromUrl url =
    Parser.parse routeParser url |> Maybe.withDefault Overview


routeFromPath : String -> Route
routeFromPath path =
    Url.fromString ("https://mctrot.nyc" ++ path)
        |> Maybe.map routeFromUrl
        |> Maybe.withDefault Overview


pathOf : Route -> String
pathOf route =
    case List.filter (\( r, _, _ ) -> r == route) tabs of
        ( _, _, path ) :: _ ->
            path

        [] ->
            "/live"


titleOf : Route -> String
titleOf route =
    case List.filter (\( r, _, _ ) -> r == route) tabs of
        ( _, label, _ ) :: _ ->
            "McTrot 5 · " ++ label

        [] ->
            "McTrot 5 · Live"


routeParser : Parser.Parser (Route -> a) a
routeParser =
    Parser.oneOf
        [ Parser.map MapTab (Parser.s "live" </> Parser.s "map")
        , Parser.map BlogTab (Parser.s "live" </> Parser.s "blog")
        , Parser.map TimelineTab (Parser.s "live" </> Parser.s "timeline")
        , Parser.map StatsTab (Parser.s "live" </> Parser.s "stats")
        ]


tabs : List ( Route, String, String )
tabs =
    [ ( MapTab, "Map", "/live/map" )
    , ( BlogTab, "Blog", "/live/blog" )
    , ( TimelineTab, "Timeline", "/live/timeline" )
    , ( StatsTab, "Stats", "/live/stats" )
    ]


routeName : Route -> String
routeName route =
    case route of
        Overview ->
            "overview"

        MapTab ->
            "map"

        BlogTab ->
            "blog"

        TimelineTab ->
            "timeline"

        StatsTab ->
            "stats"


{-| `api`: the recorder's base URL, e.g. "https://api.mctrot.nyc".
-}
type alias Flags =
    { api : String
    , radio : Radio.Flags

    -- location.pathname: which view to start on
    , path : String

    -- location.origin, e.g. "https://mctrot.nyc": where signing in returns to
    , origin : String

    -- location.hash: what to do after signing in (#like=…, Guests.elm)
    , hash : String
    }



-- /live RESPONSE (see recorder/api/live.schema.json)


type alias LiveResponse =
    { serverTs : Int
    , position : Maybe Position
    , attempt : Maybe Attempt
    , stores : List Store

    -- The planned walking route, from the route plan's GPX.
    , plannedTrack : List ( Float, Float )
    , track : List (List ( Float, Float ))
    , visits : List Visit
    , posts : List Post
    , weather : Maybe Weather
    , sun : Sun
    , sky : List SkySquare

    -- McTrot radio's now playing; Nothing without a program.
    , radio : Maybe Radio.OnAir
    }


{-| The sky's colour overhead or low in one direction ("NE"), simulated by
the recorder from the sun's position and the latest weather
(recorder/api/src/sky.ts).
-}
type alias SkySquare =
    { label : String
    , color : String
    }


{-| The latest reading in central Manhattan (Open-Meteo, every 15 minutes).
-}
type alias Weather =
    { place : String
    , observedAt : Int
    , temperatureF : Maybe Float
    , feelsLikeF : Maybe Float
    , summary : Maybe String
    , windMph : Maybe Float
    , gustMph : Maybe Float
    , windFrom : Maybe String
    }


{-| Today's sun times in New York, ms since epoch. A twilight that doesn't
happen (never, at this latitude) is Nothing.
-}
type alias Sun =
    { astronomicalDawn : Maybe Int
    , nauticalDawn : Maybe Int
    , civilDawn : Maybe Int
    , sunrise : Maybe Int
    , solarNoon : Int
    , sunset : Maybe Int
    , civilDusk : Maybe Int
    , nauticalDusk : Maybe Int
    , astronomicalDusk : Maybe Int
    }


{-| A post, newest first in the list: text, or a photo, video or voice
note once the server has processed it.
-}
type alias Post =
    { id : String
    , ts : Int
    , content : PostContent

    -- Where I was, as (lat, lon), from the GPS track; Nothing when unknown.
    , at : Maybe ( Float, Float )
    }


type PostContent
    = Text String
      -- full size, thumbnail
    | Photo String (Maybe String)
      -- the .mp4, its poster frame
    | Video String (Maybe String)
    | Voice String
    | Pair PairMedia


{-| A DoubleTake pair: the back (A) and front (B) cameras, filmed at once.
`cut` is one video that switches cameras halfway, in the pair's order;
`first` and `second` are the two clips in that order, for the
side-by-side player on wide screens (js/pair-player.js).
-}
type alias PairMedia =
    { cut : Clip
    , first : Clip
    , second : Clip
    }


type alias Clip =
    { url : String
    , posterUrl : Maybe String
    }


type alias Position =
    { ts : Int
    , lat : Float
    , lon : Float
    , accuracy : Maybe Float
    }


type alias Attempt =
    { startedAt : Int
    , endedAt : Maybe Int
    }


{-| A store in the route plan, in planned order, with its planned arrival
and departure (ms since epoch; Nothing in a hand-written plan).
-}
type alias Store =
    { id : String
    , name : String
    , address : String
    , lat : Float
    , lon : Float
    , arrive : Maybe Int
    , depart : Maybe Int
    }


{-| A check-in: when I tapped, and the store the server matched it to by
GPS.
-}
type alias Visit =
    { tapTs : Int
    , match : Match
    }


type Match
    = Matched String
    | Pending
    | Unmatched


liveDecoder : Decoder LiveResponse
liveDecoder =
    Decode.succeed LiveResponse
        |> andMap (Decode.field "serverTs" Decode.int)
        |> andMap (Decode.field "position" (Decode.nullable positionDecoder))
        |> andMap (Decode.field "attempt" (Decode.nullable attemptDecoder))
        |> andMap (Decode.field "stores" (Decode.list storeDecoder))
        -- Optional: a recorder from before the planned route sends none.
        |> andMap (Decode.oneOf [ Decode.field "plannedTrack" (Decode.list latLonDecoder), Decode.succeed [] ])
        |> andMap (Decode.field "track" (Decode.list (Decode.list latLonDecoder)))
        |> andMap (Decode.field "visits" (Decode.list visitDecoder))
        |> andMap (Decode.field "posts" (Decode.list postDecoder))
        |> andMap (Decode.field "weather" (Decode.nullable weatherDecoder))
        |> andMap (Decode.field "sun" sunDecoder)
        |> andMap
            (Decode.at [ "sky", "squares" ]
                (Decode.list
                    (Decode.map2 SkySquare
                        (Decode.field "label" Decode.string)
                        (Decode.field "color" Decode.string)
                    )
                )
            )
        -- Optional: a recorder from before the radio's program sends none.
        |> andMap (Decode.oneOf [ Decode.field "radio" (Decode.nullable Radio.onAirDecoder), Decode.succeed Nothing ])



andMap : Decoder a -> Decoder (a -> b) -> Decoder b
andMap =
    Decode.map2 (|>)


weatherDecoder : Decoder Weather
weatherDecoder =
    let
        maybe field decoder =
            Decode.field field (Decode.nullable decoder)
    in
    Decode.succeed Weather
        |> andMap (Decode.at [ "place", "name" ] Decode.string)
        |> andMap (Decode.field "observedAt" Decode.int)
        |> andMap (maybe "temperatureF" Decode.float)
        |> andMap (maybe "feelsLikeF" Decode.float)
        |> andMap (maybe "summary" Decode.string)
        |> andMap (maybe "windMph" Decode.float)
        |> andMap (maybe "gustMph" Decode.float)
        |> andMap (maybe "windFrom" Decode.string)


sunDecoder : Decoder Sun
sunDecoder =
    let
        maybe field =
            Decode.field field (Decode.nullable Decode.int)
    in
    Decode.succeed Sun
        |> andMap (maybe "astronomicalDawn")
        |> andMap (maybe "nauticalDawn")
        |> andMap (maybe "civilDawn")
        |> andMap (maybe "sunrise")
        |> andMap (Decode.field "solarNoon" Decode.int)
        |> andMap (maybe "sunset")
        |> andMap (maybe "civilDusk")
        |> andMap (maybe "nauticalDusk")
        |> andMap (maybe "astronomicalDusk")


{-| A point of the track: [lat, lon].
-}
latLonDecoder : Decoder ( Float, Float )
latLonDecoder =
    Decode.map2 Tuple.pair (Decode.index 0 Decode.float) (Decode.index 1 Decode.float)


postDecoder : Decoder Post
postDecoder =
    Decode.map4 Post
        (Decode.field "id" Decode.string)
        (Decode.field "ts" Decode.int)
        (Decode.field "type" Decode.string |> Decode.andThen postContentDecoder)
        (Decode.oneOf
            [ Decode.field "at" (Decode.nullable (Decode.map2 Tuple.pair (Decode.field "lat" Decode.float) (Decode.field "lon" Decode.float)))
            , Decode.succeed Nothing
            ]
        )


postContentDecoder : String -> Decoder PostContent
postContentDecoder postType =
    let
        media field =
            Decode.at [ "media", field ]

        optional field =
            media field (Decode.nullable Decode.string)
    in
    case postType of
        "text" ->
            Decode.map Text (Decode.field "text" Decode.string)

        "photo" ->
            Decode.map2 Photo (media "url" Decode.string) (optional "thumbUrl")

        "video" ->
            Decode.map2 Video (media "url" Decode.string) (optional "posterUrl")

        "voice" ->
            Decode.map Voice (media "url" Decode.string)

        "pair" ->
            Decode.map3
                (\cut order ( a, b ) ->
                    if order == "BA" then
                        Pair { cut = cut, first = b, second = a }

                    else
                        Pair { cut = cut, first = a, second = b }
                )
                (Decode.map2 Clip (media "url" Decode.string) (optional "posterUrl"))
                (Decode.at [ "pair", "order" ] Decode.string)
                (Decode.map2 Tuple.pair (Decode.at [ "pair", "a" ] clipDecoder) (Decode.at [ "pair", "b" ] clipDecoder))

        other ->
            Decode.fail ("unknown post type " ++ other)


clipDecoder : Decoder Clip
clipDecoder =
    Decode.map2 Clip
        (Decode.field "url" Decode.string)
        (Decode.field "posterUrl" (Decode.nullable Decode.string))


attemptDecoder : Decoder Attempt
attemptDecoder =
    Decode.map2 Attempt
        (Decode.field "startedAt" Decode.int)
        (Decode.field "endedAt" (Decode.nullable Decode.int))


storeDecoder : Decoder Store
storeDecoder =
    Decode.map7 Store
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "address" Decode.string)
        (Decode.field "lat" Decode.float)
        (Decode.field "lon" Decode.float)
        -- Optional: a recorder from before planned times sends none.
        (Decode.oneOf [ Decode.field "arrive" (Decode.nullable Decode.int), Decode.succeed Nothing ])
        (Decode.oneOf [ Decode.field "depart" (Decode.nullable Decode.int), Decode.succeed Nothing ])


visitDecoder : Decoder Visit
visitDecoder =
    Decode.map2 Visit (Decode.field "tapTs" Decode.int) matchDecoder


matchDecoder : Decoder Match
matchDecoder =
    Decode.field "status" Decode.string
        |> Decode.andThen
            (\statusName ->
                case statusName of
                    "matched" ->
                        Decode.map Matched (Decode.field "storeId" Decode.string)

                    "pending" ->
                        Decode.succeed Pending

                    "unmatched" ->
                        Decode.succeed Unmatched

                    other ->
                        Decode.fail ("unknown visit status " ++ other)
            )


positionDecoder : Decoder Position
positionDecoder =
    Decode.map4 Position
        (Decode.field "ts" Decode.int)
        (Decode.field "lat" Decode.float)
        (Decode.field "lon" Decode.float)
        (Decode.field "accuracy" (Decode.nullable Decode.float))



-- MODEL


type alias Model =
    { api : String
    , latest : Maybe Fetched
    , failing : Bool
    , now : Maybe Time.Posix
    , radio : Radio.Model

    -- What the phone's lock screen was last told is on (Radio.announce).
    , announced : Maybe Radio.NowPlaying
    , route : Route
    , zoom : Float

    -- The zoom Manhattan's outline is simplified for (see boroughAt):
    -- catches up with `zoom` just after the map's been drawn at it.
    , outlineZoom : Float
    , drag : Maybe Drag
    , dragged : Bool

    -- Two fingers on the map: their distance when the last zoom step
    -- began (see Touch).
    , pinch : Maybe Float

    -- One finger down on the map: where and when, to tell a tap from a
    -- scroll; and the last tap, for a double-tap.
    , touchStart : Maybe Tap
    , lastTap : Maybe Tap
    , focused : Maybe Focused
    , walked : List (List ( Float, Float ))

    -- Guests' likes and comments under posts (src/Guests.elm).
    , guests : Guests.Model
    , origin : String    }


{-| A drag of the map with the mouse: where the pointer was pressed and how
far the map was scrolled then.
-}
type alias Drag =
    { x : Float
    , y : Float
    , scrollX : Float
    , scrollY : Float
    }


{-| A finger on the map, in the window's coordinates, and when (the
event's timeStamp, ms).
-}
type alias Tap =
    { x : Float
    , y : Float
    , at : Float
    }


{-| A touch event on the map: the fingers still down (each at x, y), and
for touchend the one just lifted.
-}
type alias Touch =
    { down : List ( Float, Float )
    , lifted : Maybe ( Float, Float )
    , at : Float
    }


{-| What a zoom keeps in place: a point in the page's coordinates, and where
it falls across the map's box (0 to 1 each way).
-}
type alias Anchor =
    { x : Float
    , y : Float
    , fx : Float
    , fy : Float
    }


{-| A response and when this browser received it, so a position's age can
be counted from the server's clock rather than the viewer's (which may be
wrong).
-}
type alias Fetched =
    { response : LiveResponse
    , receivedAt : Time.Posix
    }


init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        route =
            routeFromPath flags.path

        ( guests, guestsCmd ) =
            Guests.init flags.api flags.hash
    in
    ( { api = flags.api
      , guests = guests
      , origin = flags.origin
      , latest = Nothing
      , failing = False
      , now = Nothing
      , radio = Radio.init flags.radio
      , announced = Nothing
      , route = route
      , zoom = 1
      , outlineZoom = 1
      , drag = Nothing
      , dragged = False
      , pinch = Nothing
      , touchStart = Nothing
      , lastTap = Nothing
      , focused = Nothing
      , walked = []
      }
    , Cmd.batch [ fetch flags.api, Task.perform Tick Time.now, setTitle (titleOf route), Cmd.map GuestsMsg guestsCmd ]
    )



-- UPDATE


type Msg
    = Poll
    | Got (Result Http.Error LiveResponse)
    | Received LiveResponse Time.Posix
    | Tick Time.Posix
    | RadioMsg Radio.Msg
    | Navigate Route
    | PathChanged String
    | Zoom Float
    | ZoomAt Float (Maybe ( Float, Float ))
    | ZoomFrom Float Anchor
    | TouchStarted Touch
    | TouchMoved Touch
    | TouchEnded Touch
    | OutlineFor Float
    | DragStart Drag
    | DragTo Float Float
    | DragEnd
    | Focus Focused
    | GuestsMsg Guests.Msg
    | NoOp


{-| What's open in a little box: on the map, a McDonald's (by id) or the
posts made at one spot (by the newest's id; see postSpots); on the
timeline, the posts made at one moment (by the newest's id; see
postMoments).
-}
type Focused
    = FocusedStore String
    | FocusedPosts String
    | FocusedMoment String


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        -- The map's + or - (zoom times 2 or 1/2), within its limits:
        -- around the middle of what's in view, or the dot that's open.
        Zoom by ->
            update (ZoomAt by Nothing) model

        -- A step in or out around a point (in the window's coordinates;
        -- Nothing for the middle of the map's frame). First see where that
        -- point falls on the map's box, before the zoom changes it.
        ZoomAt by point ->
            if clamp 1 maxZoom (model.zoom * by) == model.zoom then
                ( model, Cmd.none )

            else
                ( model
                , Task.map3
                    (\frame box page ->
                        let
                            ( x, y ) =
                                case point of
                                    Just ( cx, cy ) ->
                                        ( page.viewport.x + cx, page.viewport.y + cy )

                                    Nothing ->
                                        ( frame.element.x + frame.element.width / 2, frame.element.y + frame.element.height / 2 )
                        in
                        { x = x
                        , y = y
                        , fx = (x - box.element.x) / max 1 box.element.width
                        , fy = (y - box.element.y) / max 1 box.element.height
                        }
                    )
                    (Browser.Dom.getElement mapFrameId)
                    (Browser.Dom.getElement mapBoxId)
                    Browser.Dom.getViewport
                    |> Task.attempt (Result.map (ZoomFrom by) >> Result.withDefault NoOp)
                )

        -- Two fingers down: start counting a pinch. One: maybe a tap.
        TouchStarted touch ->
            case touch.down of
                [ a, b ] ->
                    ( { model | pinch = Just (distance a b), touchStart = Nothing }, Cmd.none )

                [ ( x, y ) ] ->
                    ( { model | touchStart = Just { x = x, y = y, at = touch.at } }, Cmd.none )

                _ ->
                    ( { model | touchStart = Nothing }, Cmd.none )

        -- A pinch steps the zoom each time the fingers spread past
        -- pinchStep (or close past 1 / pinchStep) of where the last step
        -- began, around the point between them.
        TouchMoved touch ->
            case ( model.pinch, touch.down ) of
                ( Just from, [ a, b ] ) ->
                    let
                        now =
                            distance a b

                        middle =
                            ( (Tuple.first a + Tuple.first b) / 2, (Tuple.second a + Tuple.second b) / 2 )
                    in
                    if now > from * pinchStep then
                        update (ZoomAt 2 (Just middle)) { model | pinch = Just now }

                    else if now < from / pinchStep then
                        update (ZoomAt 0.5 (Just middle)) { model | pinch = Just now }

                    else
                        ( model, Cmd.none )

                _ ->
                    ( { model | touchStart = Nothing }, Cmd.none )

        -- A finger lifted: the end of a pinch, or a tap; two taps close
        -- together in time and place zoom one step in, there.
        TouchEnded touch ->
            if model.pinch /= Nothing then
                ( { model
                    | pinch =
                        if List.length touch.down == 2 then
                            model.pinch

                        else
                            Nothing
                    , lastTap = Nothing
                  }
                , Cmd.none
                )

            else
                case ( model.touchStart, touch.lifted, touch.down ) of
                    ( Just start, Just ( x, y ), [] ) ->
                        if abs (x - start.x) + abs (y - start.y) < 12 && touch.at - start.at < 300 then
                            let
                                tap =
                                    { x = x, y = y, at = touch.at }
                            in
                            case model.lastTap of
                                Just last ->
                                    if tap.at - last.at < 350 && abs (tap.x - last.x) + abs (tap.y - last.y) < 40 then
                                        update (ZoomAt 2 (Just ( x, y ))) { model | lastTap = Nothing, touchStart = Nothing }

                                    else
                                        ( { model | lastTap = Just tap, touchStart = Nothing }, Cmd.none )

                                Nothing ->
                                    ( { model | lastTap = Just tap, touchStart = Nothing }, Cmd.none )

                        else
                            ( { model | lastTap = Nothing, touchStart = Nothing }, Cmd.none )

                    _ ->
                        ( { model | touchStart = Nothing }, Cmd.none )

        -- Dragging the map with the mouse scrolls it, so what was under
        -- the pointer stays under it. (Touch scrolls it natively.)
        DragStart drag ->
            ( { model | drag = Just drag, dragged = False }, Cmd.none )

        DragTo x y ->
            case model.drag of
                Just drag ->
                    ( { model | dragged = model.dragged || abs (x - drag.x) + abs (y - drag.y) > 4 }
                    , Browser.Dom.setViewportOf mapFrameId (drag.scrollX - (x - drag.x)) (drag.scrollY - (y - drag.y))
                        |> Task.attempt (\_ -> NoOp)
                    )

                Nothing ->
                    ( model, Cmd.none )

        DragEnd ->
            ( { model | drag = Nothing }, Cmd.none )

        -- A store's dot or a post's pin clicked: focus it, or unfocus it
        -- if it was. (Not the end of a drag that happened to finish on one.)
        Focus target ->
            if model.dragged then
                ( { model | dragged = False }, Cmd.none )

            else if model.focused == Just target then
                ( { model | focused = Nothing }, Cmd.none )

            else
                ( { model | focused = Just target }, Cmd.none )

        ZoomFrom by anchor ->
            let
                zoom =
                    clamp 1 maxZoom (model.zoom * by)
            in
            if zoom == model.zoom then
                ( model, Cmd.none )

            else
                ( { model | zoom = zoom }
                , Cmd.batch
                    [ case ( model.focused, model.pinch == Nothing && model.lastTap == Nothing ) of
                        ( Just (FocusedStore _), True ) ->
                            centreOnFocused anchor

                        ( Just (FocusedPosts _), True ) ->
                            centreOnFocused anchor

                        _ ->
                            keepAnchor anchor

                    -- Zoom first; re-simplify the outline once that's on
                    -- screen (and only for the last of several quick clicks).
                    , Task.perform (\_ -> OutlineFor zoom) (Process.sleep 150)
                    ]
                )

        OutlineFor zoom ->
            if zoom == model.zoom then
                ( { model | outlineZoom = zoom }, Cmd.none )

            else
                ( model, Cmd.none )

        -- A tab (or the title) clicked: switch views without reloading,
        -- so the radio keeps playing.
        Navigate route ->
            ( { model | route = route }
            , navigate { path = pathOf route, title = titleOf route }
            )

        -- Back or Forward.
        PathChanged path ->
            let
                route =
                    routeFromPath path
            in
            ( { model | route = route }
            , setTitle (titleOf route)
            )

        NoOp ->
            ( model, Cmd.none )

        RadioMsg radioMsg ->
            Radio.update radioMsg model.radio
                |> Tuple.mapBoth (\radio -> { model | radio = radio }) (Cmd.map RadioMsg)

        Poll ->
            ( model, Cmd.batch [ fetch model.api, Cmd.map GuestsMsg (Guests.poll model.guests) ] )

        GuestsMsg guestsMsg ->
            Guests.update guestsMsg model.guests
                |> Tuple.mapBoth (\guests -> { model | guests = guests }) (Cmd.map GuestsMsg)

        Got (Ok response) ->
            ( model, Task.perform (Received response) Time.now )

        Got (Err _) ->
            -- Keep showing the last position; the next poll retries.
            ( { model | failing = True }, Cmd.none )

        Received response at ->
            ( { model
                | latest = Just (Fetched response at)
                , failing = False
                , now = Just at
                , walked =
                    -- Snapping takes a moment: only when the path's changed.
                    if Maybe.map (.response >> .track) model.latest == Just response.track then
                        model.walked

                    else
                        walkedAlongStreets response.track
              }
            , Cmd.none
            )
                |> announceRadio

        Tick now ->
            ( { model | now = Just now }, Cmd.none )
                |> announceRadio


{-| What's on McTrot radio now, by the server's clock.
-}
radioNow : Model -> Maybe Radio.NowPlaying
radioNow model =
    Maybe.map2 Radio.nowPlaying (serverNow model) (Maybe.andThen (.response >> .radio) model.latest)


{-| Tell the phone's lock screen when what's on changes.
-}
announceRadio : ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
announceRadio ( model, cmd ) =
    case radioNow model of
        Just playing ->
            if model.announced == Just playing then
                ( model, cmd )

            else
                ( { model | announced = Just playing }, Cmd.batch [ cmd, Radio.announce playing ] )

        Nothing ->
            ( model, cmd )


{-| The path walked, in map coordinates, redrawn along the streets (see
SnapToStreets), stretch by stretch (the server splits it where GPS was
lost).
-}
walkedAlongStreets : List (List ( Float, Float )) -> List (List ( Float, Float ))
walkedAlongStreets =
    List.map (List.map (\( lat, lon ) -> Projection.toMap { lat = lat, lon = lon }) >> SnapToStreets.snap streets)


{-| The streets between McDonald's, as a network to snap the path walked to.
-}
streets : SnapToStreets.Network
streets =
    SnapToStreets.fromPath LiveMapData.networkPath


fetch : String -> Cmd Msg
fetch api =
    Http.get { url = api ++ "/live", expect = Http.expectJson Got liveDecoder }


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Sub.map RadioMsg (Radio.subscriptions model.radio)
        , pathChanged PathChanged
        , -- Overland sends every 30 s, so polling faster shows nothing new.
          Time.every 15000 (\_ -> Poll)
        , Time.every 1000 Tick
        , if model.drag == Nothing then
            Sub.none

          else
            Sub.batch
                [ Browser.Events.onMouseMove (Decode.map2 DragTo (Decode.field "clientX" Decode.float) (Decode.field "clientY" Decode.float))
                , Browser.Events.onMouseUp (Decode.succeed DragEnd)
                ]
        ]



-- VIEW


view : Model -> Html Msg
view model =
    Html.div [ Attr.class ("app page-" ++ routeName model.route) ]
        [ -- The title row and the view switcher stay at the top as the page
          -- scrolls, and the radio at the bottom (live.html, .app-top and
          -- .radio).
          Html.div [ Attr.class "app-top" ] [ viewHeader model, viewTabs model.route ]
        , Html.main_ [ Attr.id "main", Attr.class ("app-main tab-" ++ routeName model.route) ]
            (case model.route of
                Overview ->
                    viewOverview model

                MapTab ->
                    viewMapTab model

                BlogTab ->
                    viewBlogTab model

                TimelineTab ->
                    viewTimelineTab model

                StatsTab ->
                    viewStatsTab model
            )
        , Html.map RadioMsg (Radio.view (serverNow model) (radioNow model) model.radio)
        ]


{-| The title, back to the overview, and "Sign out" at the right while a
guest is signed in.
-}
viewHeader : Model -> Html Msg
viewHeader model =
    Html.header [ Attr.class "app-header" ]
        [ Html.h1 [ Attr.class "app-title" ] [ link Overview [] [ Html.text "McTROT 5" ] ]
        , Html.map GuestsMsg (Guests.viewSignOut model.guests)
        ]


{-| The views, as a row of square segments: links, so each has its own
address, with the current one marked.
-}
viewTabs : Route -> Html Msg
viewTabs current =
    Html.nav [ Attr.class "app-tabs", Attr.attribute "aria-label" "Views" ]
        [ Html.ul []
            (List.map
                (\( route, label, href ) ->
                    Html.li []
                        [ link route
                            (if route == current then
                                [ Attr.attribute "aria-current" "page" ]

                             else
                                []
                            )
                            [ Html.text label ]
                        ]
                )
                tabs
            )
        ]


{-| A link to one of the views: a real link (it can be opened in a new
tab, copied, bookmarked), but a plain click switches views in place.
-}
link : Route -> List (Html.Attribute Msg) -> List (Html Msg) -> Html Msg
link route attributes children =
    Html.a
        (Attr.href (pathOf route)
            :: Events.preventDefaultOn "click" (plainClick (Navigate route))
            :: attributes
        )
        children


{-| A left click without Cmd, Ctrl, Shift or Alt: handled here. Anything
else (open in a new tab, say) is left to the browser.
-}
plainClick : msg -> Decoder ( msg, Bool )
plainClick msg =
    Decode.map5
        (\button ctrl meta shift alt ->
            if button == 0 && not (ctrl || meta || shift || alt) then
                Decode.succeed ( msg, True )

            else
                Decode.fail "not a plain click"
        )
        (Decode.field "button" Decode.int)
        (Decode.field "ctrlKey" Decode.bool)
        (Decode.field "metaKey" Decode.bool)
        (Decode.field "shiftKey" Decode.bool)
        (Decode.field "altKey" Decode.bool)
        |> Decode.andThen identity


{-| Plain /live: one paragraph, what McTrot is and where the walk stands
(src/Status.elm), and nothing below it.
-}
viewOverview : Model -> List (Html Msg)
viewOverview model =
    [ Html.div [ Attr.class "live" ]
        [ Html.p [ Attr.class "live-paragraph" ]
            [ Html.text
                (case ( Maybe.map .response model.latest, serverNow model ) of
                    ( Just response, Just now ) ->
                        Status.paragraph (statusInput now model response)
                            ++ (if model.failing then
                                    " Can’t reach the recorder; retrying."

                                else
                                    ""
                               )

                    _ ->
                        status model
                )
            ]
        ]
    ]


{-| What the overview's paragraph is made from.
-}
statusInput : Int -> Model -> LiveResponse -> Status.Input {}
statusInput now model response =
    { now = now
    , stores = List.length response.stores
    , start =
        List.head response.stores
            |> Maybe.andThen (\first -> Maybe.map (\at -> { at = at, address = first.address }) (plannedStart response))
    , visits =
        response.stores
            |> List.filterMap
                (\store ->
                    response.visits
                        |> List.filter (\v -> v.match == Matched store.id)
                        |> List.map .tapTs
                        |> List.minimum
                        |> Maybe.map (\at -> { planned = store.arrive, at = at })
                )
    , weather =
        response.weather
            |> Maybe.map
                (\w ->
                    { summary = w.summary
                    , temperatureF = w.temperatureF
                    , feelsLikeF = w.feelsLikeF
                    , windMph = w.windMph
                    , gustMph = w.gustMph
                    , windFrom = w.windFrom
                    }
                )
    , sun = Just response.sun
    , latestPost =
        List.head response.posts
            |> Maybe.map
                (\post ->
                    { at = post.ts
                    , kind =
                        case post.content of
                            Text text ->
                                Status.TextPost text

                            Photo _ _ ->
                                Status.PhotoPost

                            Video _ _ ->
                                Status.VideoPost

                            Pair _ ->
                                Status.VideoPost

                            Voice _ ->
                                Status.VoicePost
                    }
                )
    , radio = radioNow model |> Maybe.map (\{ title, artist } -> { title = title, artist = artist })
    }


{-| The map's chip: "9:16 PM · 14 min ago", or how the connection's going.
-}
positionChip : Model -> String
positionChip model =
    case ( Maybe.andThen (.response >> .position) model.latest, serverNow model ) of
        ( Just position, Just now ) ->
            NewYorkTime.clock position.ts
                ++ " · "
                ++ duration (now - position.ts)
                ++ " ago"
                ++ (if model.failing then
                        " · offline"

                    else
                        ""
                   )

        _ ->
            status model


viewStatus : Model -> Html Msg
viewStatus model =
    Html.p [ Attr.class "live-status", Attr.attribute "aria-live" "polite" ] [ Html.text (status model) ]


{-| The map, filling the space between the tabs and the radio,
mapTabStretch times as wide as Manhattan's true proportions (see viewMap),
less as it's zoomed in (see stretchAt), and zoomable: + and - at its top
right, a pinch, or a double-tap; then drag or scroll to look around. The
last position floats at its top left.
-}
viewMapTab : Model -> List (Html Msg)
viewMapTab model =
    [ Html.p [ Attr.class "live-map-chip", Attr.attribute "aria-live" "polite" ] [ Html.text (positionChip model) ]
    , viewMap (Just { stretch = stretchAt model.zoom, zoom = model.zoom, outlineZoom = model.outlineZoom, dragging = model.drag /= Nothing }) model.focused model.walked (serverNow model) (Maybe.map .response model.latest)
    ]


{-| Manhattan's outline, as simple as this zoom allows: a handful of
points all the way out (zoom 1, level 100), every point all the way in
(maxZoom, level 0), evenly between on the same log scale as the zoom
steps. Ranked once (src/Simplify.elm).
-}
boroughAt : Float -> String
boroughAt zoom =
    (Simplify.atLevel (100 * (1 - logBase 2 zoom / logBase 2 maxZoom)) boroughRanked).d


{-| Lazy, so the path is only rebuilt when the zoom changes, not on every
redraw (a drag redraws many times a second).
-}
viewBorough : Float -> Svg msg
viewBorough zoom =
    Svg.path [ SvgAttr.class "live-borough", SvgAttr.d (boroughAt zoom) ] []


boroughRanked : Simplify.Ranked
boroughRanked =
    Simplify.rank LiveMapData.boroughPath


maxZoom : Float
maxZoom =
    16


mapFrameId : String
mapFrameId =
    "live-map-frame"


{-| After a zoom, scroll the map so the same place on it is back under the
anchor point (the middle of the frame, or the fingers). Measured on the
box itself, so the margin around it when zoomed in and its stretch, which
eases with each step, both take care of themselves. (Browser.Dom measures
once the page is drawn at the new size.)
-}
keepAnchor : Anchor -> Cmd Msg
keepAnchor anchor =
    keepAnchorTask anchor |> Task.attempt (\_ -> NoOp)


keepAnchorTask : Anchor -> Task.Task Browser.Dom.Error ()
keepAnchorTask anchor =
    Task.map2 Tuple.pair (Browser.Dom.getElement mapBoxId) (Browser.Dom.getViewportOf mapFrameId)
        |> Task.andThen
            (\( box, frame ) ->
                Browser.Dom.setViewportOf mapFrameId
                    (frame.viewport.x + box.element.x + anchor.fx * box.element.width - anchor.x)
                    (frame.viewport.y + box.element.y + anchor.fy * box.element.height - anchor.y)
            )


{-| How far two fingers must spread (or close, by its inverse) to step the
zoom: a guess, to tune on a phone.
-}
pinchStep : Float
pinchStep =
    1.5


distance : ( Float, Float ) -> ( Float, Float ) -> Float
distance ( x1, y1 ) ( x2, y2 ) =
    sqrt ((x1 - x2) ^ 2 + (y1 - y2) ^ 2)


{-| A touch event: the fingers down, the one lifted (touchend), and when.
-}
touchDecoder : Decoder Touch
touchDecoder =
    let
        point =
            Decode.map2 Tuple.pair (Decode.field "clientX" Decode.float) (Decode.field "clientY" Decode.float)

        list field =
            Decode.field field (Decode.field "length" Decode.int)
                |> Decode.andThen
                    (\n ->
                        List.range 0 (min 2 n - 1)
                            |> List.map (\i -> Decode.field field (Decode.field (String.fromInt i) point))
                            |> List.foldr (Decode.map2 (::)) (Decode.succeed [])
                    )
    in
    Decode.map3 Touch
        (list "touches")
        (list "changedTouches" |> Decode.map List.head)
        (Decode.field "timeStamp" Decode.float)


mapBoxId : String
mapBoxId =
    "live-map-box"


{-| After a zoom with a dot selected on the map (a McDonald's or a post's),
scroll so that dot's in the middle of the view; if it can't be found, keep
the anchor in place (keepAnchor).
-}
centreOnFocused : Anchor -> Cmd Msg
centreOnFocused before =
    Task.map3
        (\frame dot after ->
            { x = after.viewport.x + (dot.element.x + dot.element.width / 2 - frame.element.x) - after.viewport.width / 2
            , y = after.viewport.y + (dot.element.y + dot.element.height / 2 - frame.element.y) - after.viewport.height / 2
            }
        )
        (Browser.Dom.getElement mapFrameId)
        (Browser.Dom.getElement focusedDotId)
        (Browser.Dom.getViewportOf mapFrameId)
        |> Task.andThen (\{ x, y } -> Browser.Dom.setViewportOf mapFrameId x y)
        |> Task.onError (\_ -> keepAnchorTask before)
        |> Task.attempt (\_ -> NoOp)


{-| The id of the selected dot on the map, for centreOnFocused.
-}
focusedDotId : String
focusedDotId =
    "live-map-focused-dot"


viewZoomButtons : Float -> Html Msg
viewZoomButtons zoom =
    Html.div [ Attr.class "live-map-zoom" ]
        [ Html.button
            [ Attr.type_ "button"
            , Events.onClick (Zoom 2)
            , Attr.disabled (zoom >= maxZoom)
            , Attr.attribute "aria-label" "Zoom in"
            ]
            [ Html.text "+" ]
        , Html.button
            [ Attr.type_ "button"
            , Events.onClick (Zoom 0.5)
            , Attr.disabled (zoom <= 1)
            , Attr.attribute "aria-label" "Zoom out"
            ]
            [ Html.text "−" ]
        ]


{-| How much wider than true the Map tab's map is when zoomed all the way
out: picked by eye with a slider.
-}
mapTabStretch : Float
mapTabStretch =
    3.6


{-| The Map tab's stretch at a zoom: mapTabStretch all the way out, easing
by the same factor each step in, to 1 (true proportions) all the way in, at
maxZoom. Roughly 3.6, 2.6, 1.9, 1.4, 1.
-}
stretchAt : Float -> Float
stretchAt zoom =
    mapTabStretch ^ (1 - logBase 2 zoom / logBase 2 maxZoom)


{-| The posts, newest first, scrolling down the page. (When the walk
starts is the overview's to say.)
-}
viewBlogTab : Model -> List (Html Msg)
viewBlogTab model =
    case Maybe.map .response model.latest of
        Just response ->
            if List.isEmpty response.posts then
                [ Html.p [ Attr.class "tab-empty" ] [ Html.text "No posts yet." ] ]

            else
                [ viewPosts model ]

        Nothing ->
            [ Html.p [ Attr.class "tab-empty" ] [ Html.text (status model) ] ]


{-| When the walk is planned to start: the plan's first arrival (Nothing
in a hand-written plan without times).
-}
plannedStart : LiveResponse -> Maybe Int
plannedStart response =
    List.filterMap .arrive response.stores |> List.minimum


{-| A burndown chart of the McDonald's still to visit, plan against
actual, under a time ruler (see Burndown).
-}
viewTimelineTab : Model -> List (Html Msg)
viewTimelineTab model =
    case ( Maybe.map .response model.latest, serverNow model ) of
        ( Just response, Just now ) ->
            let
                stores =
                    response.stores

                latitudes =
                    latitudeScale

                firstVisits =
                    stores
                        |> List.filterMap
                            (\store ->
                                response.visits
                                    |> List.filter (\v -> v.match == Matched store.id)
                                    |> List.map .tapTs
                                    |> List.minimum
                            )
            in
            [ Burndown.view
                { items =
                    postMoments (onWalkDay stores) response.posts
                        |> List.filterMap
                            (\posts ->
                                case posts of
                                    newest :: _ ->
                                        Maybe.map
                                            (\( lat, _ ) ->
                                                { at = onWalkDay stores newest.ts
                                                , y = latitudes.y lat
                                                , draw =
                                                    \at ->
                                                        let
                                                            target =
                                                                FocusedMoment (momentId posts)
                                                        in
                                                        Html.div []
                                                            [ postDot model.focused target posts []
                                                            , if model.focused == Just target then
                                                                postsBox (Just now)
                                                                    target
                                                                    posts
                                                                    [ ( "live-focus-left", at.x > 0.55 )
                                                                    , ( "live-focus-below", at.y < 0.35 )
                                                                    , ( "live-focus-above", at.y > 0.65 )
                                                                    ]
                                                                    []

                                                              else
                                                                Html.text ""
                                                            ]
                                                }
                                            )
                                            newest.at

                                    [] ->
                                        Nothing
                            )
                , axis = latitudes.axis
                , key = "Posts, by latitude"
                }
                { plan = List.filterMap .arrive stores
                , planEnd =
                    List.filterMap .depart stores
                        ++ List.filterMap .arrive stores
                        |> List.maximum
                        |> Maybe.withDefault 0
                , visits = firstVisits
                , total = List.length stores
                , now = now
                }
            ]

        _ ->
            [ Html.p [ Attr.class "tab-empty" ] [ Html.text (status model) ] ]


{-| A grid of cells filling the page. (How it subdivides and collapses
comes in a later pass.)
-}
viewStatsTab : Model -> List (Html Msg)
viewStatsTab model =
    let
        response =
            Maybe.map .response model.latest

        cell title body =
            Html.section [ Attr.class "stats-cell" ] (Html.h2 [] [ Html.text title ] :: body)
    in
    [ Html.div [ Attr.class "stats-grid" ]
        [ cell "Status" [ Html.p [] [ Html.text (statusLine model) ] ]
        , Html.section [ Attr.class "stats-cell stats-cell-conditions" ]
            [ Html.h2 [] [ Html.text "Conditions" ]
            , viewWeatherAfter (solarTime model) False model
            , viewSky response
            ]
        , Html.section [ Attr.class "stats-cell stats-cell-plan" ]
            [ Html.h2 [] [ Html.text "Plan" ]
            , viewPlan
                (Maybe.map .stores response |> Maybe.withDefault [])
                (Maybe.map .visits response |> Maybe.withDefault [])
            ]
        ]
    ]


{-| The route plan as a schedule, like the simulator's printout
(Simulator.elm, viewPrintSchedule): nickname, address, expected
and actual arrival, the difference, and expected departure, in New York
time. A time on a new day (the first, or after midnight) shows the date
as well.

Actual arrival is the time of the check-in (Check In on the upload page)
that the recorder matched to that store by GPS. The difference is
expected minus actual: positive (green) when ahead of plan, negative
(red) when behind.
-}
viewPlan : List Store -> List Visit -> Html Msg
viewPlan stores visits =
    if List.isEmpty stores then
        Html.p [] [ Html.text "No route plan loaded." ]

    else
        let
            dayOf ms =
                NewYorkTime.format ms |> String.split "," |> List.head

            -- A time, with its date if it's on a different day from the
            -- time before it.
            timeCell before time =
                Html.td [ Attr.class "plan-time" ]
                    [ Html.text
                        (case time of
                            Just ms ->
                                if Maybe.andThen dayOf before == dayOf ms then
                                    NewYorkTime.clock ms

                                else
                                    NewYorkTime.formatShort ms

                            Nothing ->
                                "—"
                        )
                    ]

            checkedIn store =
                visits
                    |> List.filter (\visit -> visit.match == Matched store.id)
                    |> List.head
                    |> Maybe.map .tapTs

            difference store =
                case ( store.arrive, checkedIn store ) of
                    ( Just expected, Just actual ) ->
                        let
                            minutes =
                                round (toFloat (expected - actual) / 60000)

                            ( sign, class ) =
                                if minutes > 0 then
                                    ( "+", "plan-ahead" )

                                else if minutes < 0 then
                                    ( "−", "plan-behind" )

                                else
                                    ( "", "" )
                        in
                        Html.td [ Attr.class ("plan-time plan-diff " ++ class) ]
                            [ Html.text
                                (if minutes == 0 then
                                    "on time"

                                 else
                                    sign ++ duration (abs minutes * 60000)
                                )
                            ]

                    _ ->
                        Html.td [ Attr.class "plan-time plan-diff" ] [ Html.text "—" ]

            row ( previous, store ) =
                Html.tr []
                    [ Html.td [] [ Html.text store.name ]
                    , Html.td [] [ Html.text store.address ]
                    , timeCell (Maybe.andThen .depart previous) store.arrive
                    , timeCell store.arrive (checkedIn store)
                    , difference store
                    , timeCell store.arrive store.depart
                    ]
        in
        Html.table [ Attr.class "plan-schedule" ]
            [ Html.thead []
                [ Html.tr []
                    [ Html.th [] [ Html.text "Nickname" ]
                    , Html.th [] [ Html.text "Address" ]
                    , Html.th [] [ Html.text "Expected arrival" ]
                    , Html.th [] [ Html.text "Actual arrival" ]
                    , Html.th [] [ Html.text "Difference" ]
                    , Html.th [] [ Html.text "Expected departure" ]
                    ]
                ]
            , Html.tbody []
                (List.map row (List.map2 Tuple.pair (Nothing :: List.map Just stores) stores))
            ]


{-| "54°F, clear, feels like 47°F. Wind 9 mph from the NW, gusts 12 mph."
-}
viewWeather : Model -> Html Msg
viewWeather model =
    viewWeatherAfter Nothing True model


{-| The time of day by the sun now ("Civil twilight", "2 hours before solar
noon"; see SolarTime), from today's sun times.
-}
solarTime : Model -> Maybe String
solarTime model =
    Maybe.map2 (\now { response } -> SolarTime.describe now response.sun) (serverNow model) model.latest


{-| The weather sentence, after `lead` if there is one ("Civil twilight.
44°F, clear, …"), and where and when it was observed ("Central Manhattan,
10 min ago") if `withSource`. Just the lead before any weather's been
fetched.
-}
viewWeatherAfter : Maybe String -> Bool -> Model -> Html Msg
viewWeatherAfter lead withSource model =
    let
        leading =
            lead |> Maybe.map (\text -> text ++ ". ") |> Maybe.withDefault ""
    in
    case ( Maybe.andThen (.response >> .weather) model.latest, serverNow model ) of
        ( Just w, Just now ) ->
            let
                degrees f =
                    String.fromInt (round f) ++ "°F"

                mph f =
                    String.fromInt (round f) ++ " mph"

                first =
                    [ Maybe.map degrees w.temperatureF
                    , Maybe.map String.toLower w.summary
                    , Maybe.map (\f -> "feels like " ++ degrees f) w.feelsLikeF
                    ]
                        |> List.filterMap identity
                        |> String.join ", "

                wind =
                    case w.windMph of
                        Just speed ->
                            "Wind "
                                ++ mph speed
                                ++ (w.windFrom |> Maybe.map (\d -> " from the " ++ d) |> Maybe.withDefault "")
                                ++ (w.gustMph |> Maybe.map (\g -> ", gusts " ++ mph g) |> Maybe.withDefault "")
                                ++ "."

                        Nothing ->
                            ""
            in
            Html.p [ Attr.class "live-weather" ]
                [ Html.text (leading ++ capitalize first ++ ". " ++ wind)
                , if withSource then
                    Html.span [ Attr.class "live-weather-when" ]
                        [ Html.text (" " ++ w.place ++ ", " ++ when now w.observedAt ++ ".") ]

                  else
                    Html.text ""
                ]

        _ ->
            case lead of
                Just text ->
                    Html.p [ Attr.class "live-weather" ] [ Html.text (text ++ ".") ]

                Nothing ->
                    Html.text ""


{-| The sky now, as coloured tiles labelled with where to look: a row on a
phone, a column pinned to the bottom-left corner on a wide screen
(live.html).
-}
viewSky : Maybe LiveResponse -> Html Msg
viewSky response =
    case Maybe.map .sky response of
        Just ((_ :: _) as squares) ->
            Html.figure
                [ Attr.class "live-sky"
                , Attr.title "The sky now, simulated from the sun and the weather"
                ]
                [ Html.ul []
                    (List.map
                        (\square ->
                            Html.li []
                                [ Html.span
                                    [ Attr.class "live-sky-swatch"
                                    , Attr.style "background-color" square.color
                                    , Attr.attribute "role" "img"
                                    , Attr.attribute "aria-label" (square.label ++ ": " ++ square.color)
                                    ]
                                    []
                                , Html.span [ Attr.class "live-sky-label" ] [ Html.text square.label ]
                                ]
                        )
                        squares
                    )
                ]

        _ ->
            Html.text ""


capitalize : String -> String
capitalize text =
    String.toUpper (String.left 1 text) ++ String.dropLeft 1 text


{-| Today's sunrise, sunset and twilights, in New York time.
-}
viewSun : Maybe LiveResponse -> Html Msg
viewSun response =
    case response of
        Just { sun } ->
            let
                time =
                    Maybe.map NewYorkTime.clock >> Maybe.withDefault "—"

                row label morning evening =
                    Html.tr []
                        [ Html.th [ Attr.scope "row" ] [ Html.text label ]
                        , Html.td [] [ Html.text (time morning) ]
                        , Html.td [] [ Html.text (time evening) ]
                        ]
            in
            Html.table [ Attr.class "live-sun" ]
                [ Html.caption [] [ Html.text ("Today’s sun · solar noon " ++ NewYorkTime.clock sun.solarNoon) ]
                , Html.thead []
                    [ Html.tr []
                        [ Html.td [] []
                        , Html.th [ Attr.scope "col" ] [ Html.text "Morning" ]
                        , Html.th [ Attr.scope "col" ] [ Html.text "Evening" ]
                        ]
                    ]
                , Html.tbody []
                    [ row "Astronomical twilight" sun.astronomicalDawn sun.astronomicalDusk
                    , row "Nautical twilight" sun.nauticalDawn sun.nauticalDusk
                    , row "Civil twilight" sun.civilDawn sun.civilDusk
                    , row "Sunrise, sunset" sun.sunrise sun.sunset
                    ]
                ]

        Nothing ->
            Html.text ""


{-| The server's clock now: its time at the last response, plus however
long ago this browser received it. Ages and durations count from this, so
a viewer's wrong clock doesn't matter.
-}
serverNow : Model -> Maybe Int
serverNow model =
    model.latest
        |> Maybe.map
            (\{ response, receivedAt } ->
                let
                    sinceReceived =
                        case model.now of
                            Just now ->
                                max 0 (Time.posixToMillis now - Time.posixToMillis receivedAt)

                            Nothing ->
                                0
                in
                response.serverTs + sinceReceived
            )


status : Model -> String
status model =
    let
        problem =
            if model.failing then
                " Can’t reach the recorder; retrying."

            else
                ""
    in
    case ( model.latest, serverNow model ) of
        ( Just { response }, Just now ) ->
            case response.position of
                Nothing ->
                    "No position yet." ++ problem

                Just position ->
                    "Last position " ++ when now position.ts ++ "." ++ problem

        _ ->
            if model.failing then
                "Can’t reach the recorder; retrying."

            else
                "Connecting…"


{-| Stats' status: "5 of 46 restaurants visited. Last position November
21, 5:34 AM EST." (each restaurant counted once, however many check-ins
it's had), or how the connection's going before there's anything.
-}
statusLine : Model -> String
statusLine model =
    case Maybe.map .response model.latest of
        Just response ->
            let
                visited =
                    response.stores
                        |> List.filter (\store -> List.any (\v -> v.match == Matched store.id) response.visits)
                        |> List.length
            in
            String.fromInt visited
                ++ " of "
                ++ String.fromInt (List.length response.stores)
                ++ " restaurants visited. "
                ++ status model

        Nothing ->
            status model


{-| "Visits 3 / 46 · 1 checking in". Attempts are set aside for now (the
recorder's USE_ATTEMPTS), so every check-in counts and there's no "on the
road for".
-}
visitsLine : Model -> String
visitsLine model =
    case Maybe.map .response model.latest of
        Just response ->
            let
                count status_ =
                    List.length (List.filter (.match >> status_) response.visits)

                extra label n =
                    if n > 0 then
                        " · " ++ String.fromInt n ++ " " ++ label

                    else
                        ""
            in
            "Visits "
                ++ String.fromInt (count isMatched)
                ++ " / "
                ++ String.fromInt (List.length response.stores)
                ++ extra "checking in" (count ((==) Pending))
                ++ extra "unmatched" (count ((==) Unmatched))
                ++ "."

        Nothing ->
            ""


isMatched : Match -> Bool
isMatched match =
    case match of
        Matched _ ->
            True

        _ ->
            False


{-| "12 min ago" for the first two hours, then the date and time in New
York, for every visitor: "November 21, 5:34 AM EST".
-}
when : Int -> Int -> String
when now ts =
    if now - ts < 2 * 3600000 then
        duration (now - ts) ++ " ago"

    else
        NewYorkTime.format ts


duration : Int -> String
duration ms =
    let
        seconds =
            max 0 ms // 1000
    in
    if seconds < 60 then
        String.fromInt seconds ++ " s"

    else if seconds < 3600 then
        String.fromInt (seconds // 60) ++ " min"

    else if seconds < 2 * 86400 then
        String.fromInt (seconds // 3600) ++ " h " ++ String.fromInt (modBy 60 (seconds // 60)) ++ " min"

    else
        String.fromInt (seconds // 86400) ++ " days"


{-| The map, stretched to fill its box like the simulator's "Stretch" map:
LiveMapData.stretchViewBox (just the McDonald's and the streets between
them) pulled to the box's width and height, with Manhattan spilling into
the padding around it (see .live-map-frame in live.html).

With a `shape`, the box is the frame's full height and `stretch` times as
wide as Manhattan's true proportions would make it (1 is undistorted), but
never wider than the frame; then all of that times `zoom`, with the frame
scrolling to show the rest, + and - buttons, and dragging with the mouse
(a hand cursor, closed while `dragging`). Without one, it fills the frame.

Zooming only spreads places apart: lines, dots and flags stay their size.

Only places stretch. Lines keep their widths (non-scaling strokes), the
dots and the last position are the ends of zero-length strokes, which keep
their shape, and the flags are small pictures of their own, pinned by
percentage. All sizes are in live.html, in screen pixels.

Bottom to top: Manhattan (light grey; simpler the further out, see
boroughAt), every street between McDonald's
(thin white), the start and finish flags, the planned route and the stores
(thick white and white dots, with every black outline drawn first so the
route and the dots join into one shape), the path walked (red, over the
white dots of the stores visited but under the rest, `walked`: redrawn
along the streets), a small dot of colour inside each white one (yellow; red once
visited; dark yellow while closed), and the last position (a small red
square). Over everything, each dot can be clicked to focus its store (one
at a time; click again to unfocus), which shows a little box beside it with
its name and when it next opens or closes (see viewFocus).
-}
viewMap : Maybe { stretch : Float, zoom : Float, outlineZoom : Float, dragging : Bool } -> Maybe Focused -> List (List ( Float, Float )) -> Maybe Int -> Maybe LiveResponse -> Html Msg
viewMap shape focused walked now response =
    let
        position =
            Maybe.andThen .position response

        placed =
            Maybe.map (\p -> Projection.toMap { lat = p.lat, lon = p.lon }) position

        stores =
            Maybe.map .stores response |> Maybe.withDefault []

        spots =
            Maybe.map .posts response |> Maybe.withDefault [] |> postSpots

        visited =
            Maybe.map .visits response
                |> Maybe.withDefault []
                |> List.filterMap
                    (\v ->
                        case v.match of
                            Matched id ->
                                Just id

                            _ ->
                                Nothing
                    )

        -- When I first checked in at a store, if I have.
        firstVisit id =
            Maybe.map .visits response
                |> Maybe.withDefault []
                |> List.filter (\v -> v.match == Matched id)
                |> List.map .tapTs
                |> List.minimum

        pipClass store =
            if List.member store.id visited then
                "live-pip live-pip-visited"

            else if now |> Maybe.map (\ms -> not (isOpen ms store)) |> Maybe.withDefault False then
                "live-pip live-pip-closed"

            else
                "live-pip"

        planned =
            Maybe.map .plannedTrack response |> Maybe.withDefault []

        plannedLine class =
            if List.isEmpty planned then
                []

            else
                [ viewLine class planned ]

        layer =
            Svg.svg
                [ SvgAttr.viewBox LiveMapData.stretchViewBox
                , SvgAttr.preserveAspectRatio "none"
                , SvgAttr.class "live-map-layer"
                ]
    in
    Html.div [ Attr.class "live-map" ]
        [ shape |> Maybe.map (.zoom >> viewZoomButtons) |> Maybe.withDefault (Html.text "")
        , Html.div
            [ Attr.class "live-map-frame"
            , Attr.id mapFrameId
            , Attr.classList
                [ ( "live-map-draggable", shape /= Nothing )
                , ( "live-map-dragging", Maybe.map .dragging shape == Just True )
                ]
            , case shape of
                Just _ ->
                    Events.preventDefaultOn "mousedown" (Decode.map (\drag -> ( DragStart drag, True )) dragStart)

                Nothing ->
                    Attr.class ""
            , onTouch shape "touchstart" TouchStarted
            , onTouch shape "touchmove" TouchMoved
            , onTouch shape "touchend" TouchEnded
            , onTouch shape "touchcancel" TouchEnded
            , Attr.attribute "role" "img"
            , Attr.attribute "aria-label" "Map of Manhattan, stretched to fill the page: the streets between McDonald's, the planned route from start flag to finish flag, the path I've walked, every McDonald's (visited, not yet, or closed now) and my last position"
            ]
            [ -- Zoomed in, the box gets half a frame of empty margin all
              -- round (live.html, .live-map-zoomed), so any place on it,
              -- even at its edge, can be scrolled to the middle.
              Html.div
                [ Attr.class "live-map-scene"
                , Attr.classList [ ( "live-map-zoomed", Maybe.map .zoom shape |> Maybe.map (\z -> z > 1) |> Maybe.withDefault False ) ]
                ]
                [ Html.div
                (Attr.class "live-map-box"
                    :: (case ( shape, stretchBox ) of
                            ( Just { stretch, zoom }, [ _, _, width, height ] ) ->
                                [ Attr.id mapBoxId
                                , Attr.style "aspect-ratio" (String.fromFloat (width * stretch) ++ " / " ++ String.fromFloat height)
                                , Attr.style "height" (String.fromFloat (zoom * 100) ++ "cqh")
                                , Attr.style "max-width" (String.fromFloat (zoom * 100) ++ "cqw")
                                ]

                            _ ->
                                []
                       )
                )
                [ layer
                    [ Svg.Lazy.lazy viewBorough (Maybe.map .outlineZoom shape |> Maybe.withDefault 1)
                    , Svg.path [ SvgAttr.class "live-network", SvgAttr.d LiveMapData.networkPath ] []
                    ]
                , Html.div [ Attr.class "live-map-layer" ]
                    ((List.head planned |> Maybe.andThen (nearestStore stores) |> Maybe.map (\start -> [ viewFlag Start start ]) |> Maybe.withDefault [])
                        ++ (List.head (List.reverse planned) |> Maybe.andThen (nearestStore stores) |> Maybe.map (\end -> [ viewFlag Finish end ]) |> Maybe.withDefault [])
                    )
                , layer
                    (plannedLine "live-planned-casing"
                        ++ List.map (viewStore "live-store-casing") stores
                        ++ plannedLine "live-planned"
                        -- A visited store's white dot goes under the path
                        -- walked, which ran through it; one not visited yet
                        -- goes over, so a path passing by doesn't cross it.
                        ++ List.map (viewStore "live-store") (List.filter (\store -> List.member store.id visited) stores)
                        ++ List.map viewTrack walked
                        ++ List.map (viewStore "live-store") (List.filter (\store -> not (List.member store.id visited)) stores)
                        ++ List.map (\store -> viewStore (pipClass store) store) stores
                        ++ (placed |> Maybe.map viewMe |> Maybe.withDefault [])
                        ++ List.map (\store -> viewStoreHit (focused == Just (FocusedStore store.id)) store) stores
                    )
                , Html.div [ Attr.class "live-map-layer" ]
                    (List.map (viewPostPin focused) spots)
                , Html.div [ Attr.class "live-map-layer" ]
                    ((stores
                        |> List.filter (\store -> Just (FocusedStore store.id) == focused)
                        |> List.map (\store -> viewFocus now (firstVisit store.id) store)
                     )
                        ++ (spots
                                |> List.filter (\spot -> Just (FocusedPosts (spotId spot)) == focused)
                                |> List.map (viewPostsFocus now)
                           )
                    )
                ]
                ]
            ]
        , if placed /= Nothing && not (onMap placed) then
            Html.p [ Attr.class "live-note" ] [ Html.text "The last position is off this map." ]

          else
            Html.text ""
        ]


{-| A touch handler on the zoomable map; nothing on a fixed one.
-}
onTouch : Maybe a -> String -> (Touch -> Msg) -> Html.Attribute Msg
onTouch shape event toMsg =
    case shape of
        Just _ ->
            Events.on event (Decode.map toMsg touchDecoder)

        Nothing ->
            Attr.class ""


{-| The store whose dot a flag goes over: the one nearest an end of the
planned route, which starts and finishes on the sidewalk a little off the
store's own point. As [lat, lon], like the route.
-}
nearestStore : List Store -> ( Float, Float ) -> Maybe ( Float, Float )
nearestStore stores ( lat, lon ) =
    stores
        |> List.sortBy (\store -> (store.lat - lat) ^ 2 + ((store.lon - lon) * cos (degrees lat)) ^ 2)
        |> List.head
        |> Maybe.map (\store -> ( store.lat, store.lon ))


{-| A press of the main mouse button on the map: where, and how far the
map (the event's currentTarget) is scrolled.
-}
dragStart : Decoder Drag
dragStart =
    Decode.field "button" Decode.int
        |> Decode.andThen
            (\button ->
                if button == 0 then
                    Decode.map4 Drag
                        (Decode.field "clientX" Decode.float)
                        (Decode.field "clientY" Decode.float)
                        (Decode.at [ "currentTarget", "scrollLeft" ] Decode.float)
                        (Decode.at [ "currentTarget", "scrollTop" ] Decode.float)

                else
                    Decode.fail "not the main button"
            )


{-| Where a point in map coordinates sits in the stretched map's box, as
CSS percentages from its left and top.
-}
boxPercent : ( Float, Float ) -> Maybe ( String, String )
boxPercent ( x, y ) =
    case stretchBox of
        [ minX, minY, width, height ] ->
            Just
                ( String.fromFloat ((x - minX) / width * 100) ++ "%"
                , String.fromFloat ((y - minY) / height * 100) ++ "%"
                )

        _ ->
            Nothing


stretchBox : List Float
stretchBox =
    LiveMapData.stretchViewBox |> String.words |> List.filterMap String.toFloat


{-| Whether a McDonald's is open at this moment, from its weekly hours
(LiveMapData.openWindows). A store without hours (a hand-written plan's)
counts as open.
-}
isOpen : Int -> Store -> Bool
isOpen ms store =
    case Dict.get store.id LiveMapData.openWindows of
        Just windows ->
            let
                minute =
                    NewYorkTime.minuteOfWeek ms
            in
            List.any (\( from, to ) -> minute >= from && minute < to) windows

        Nothing ->
            True


{-| One stretch of the path walked, along the streets (see
walkedAlongStreets), already in map coordinates.
-}
viewTrack : List ( Float, Float ) -> Svg Msg
viewTrack segment =
    Svg.polyline
        [ SvgAttr.class "live-track"
        , SvgAttr.points
            (segment
                |> List.map (\( x, y ) -> String.fromFloat (toFloat (round (x * 10)) / 10) ++ "," ++ String.fromFloat (toFloat (round (y * 10)) / 10))
                |> String.join " "
            )
        ]
        []


{-| A line through [lat, lon] points, in map coordinates.
-}
viewLine : String -> List ( Float, Float ) -> Svg Msg
viewLine class segment =
    Svg.polyline
        [ SvgAttr.class class
        , SvgAttr.points
            (segment
                |> List.map
                    (\( lat, lon ) ->
                        let
                            ( x, y ) =
                                Projection.toMap { lat = lat, lon = lon }
                        in
                        String.fromFloat (toFloat (round (x * 10)) / 10) ++ "," ++ String.fromFloat (toFloat (round (y * 10)) / 10)
                    )
                |> String.join " "
            )
        ]
        []


{-| A flag at the start (green) or the end (checkered) of the course, at
the store where the planned route starts or finishes (see nearestStore): a waving flag centred just
above the store's dot (flagBesideX, flagBesideY). It's drawn as if
held by a leaning pole, which isn't drawn. It's a small picture of its own, pinned by percentage to its
place on the stretched map (see viewMap), so it never stretches. Its
drawing is in flag units, flagUnitsPerPixel to a screen pixel. It's drawn
under the route and the dots.

The (unseen) pole stands on the point and leans left (its top is flagPoleFoot left
of its foot), so it slopes down from left to right. The flag hangs upright
from the top, its left edge along the pole (see flagPoint). The checks are
drawn one by one, shaped like the cloth, so they wave and lean with it.
-}
viewFlag : Flag -> ( Float, Float ) -> Html Msg
viewFlag flag ( lat, lon ) =
    let
        ( name, cloth ) =
            case flag of
                Start ->
                    ( "Start", "live-flag-cloth live-flag-start" )

                Finish ->
                    ( "Finish", "live-flag-cloth live-flag-finish" )

        whole =
            flagShape ( 0, 1200 ) ( 0, 750 )

        -- The picture's frame, in flag units around the pole's foot (0, 0),
        -- with room for the outline.
        ( left, top ) =
            ( -400, -2260 )

        ( width, height ) =
            ( 1360, 2320 )

        px units =
            String.fromFloat (units / flagUnitsPerPixel) ++ "px"
    in
    case boxPercent (Projection.toMap { lat = lat, lon = lon }) of
        Just ( pinLeft, pinTop ) ->
            Html.div
                [ Attr.class "live-flag-pin"
                , Attr.style "left" pinLeft
                , Attr.style "top" pinTop
                ]
                [ Svg.svg
                    [ SvgAttr.class "live-flag"
                    , SvgAttr.viewBox (String.join " " (List.map String.fromFloat [ left, top, width, height ]))
                    , Attr.style "left" (px (left + flagBesideX))
                    , Attr.style "top" (px (top + flagBesideY))
                    , Attr.style "width" (px width)
                    , Attr.style "height" (px height)
                    ]
                    [ Svg.title [] [ Svg.text name ]
                    , Svg.g [ SvgAttr.transform ("translate(" ++ String.fromFloat -flagPoleFoot ++ ",0)") ]
                        ([ Svg.polygon [ SvgAttr.class cloth, SvgAttr.points whole ] [] ]
                            ++ (if flag == Finish then
                                    flagChecks

                                else
                                    []
                               )
                            ++ [ Svg.polygon [ SvgAttr.class "live-flag-outline", SvgAttr.points whole ] [] ]
                        )
                    ]
                ]

        Nothing ->
            Html.text ""


{-| How far (in flag units) the flag is moved from where the unseen pole
would hold it, to sit centred just above its dot instead: the cloth's
middle (600 along and 375 down, see flagPoint) over the dot's centre, and its lowest point (the wave's trough, 75
below the cloth's bottom, which is flagPoleHeight - 750 above the foot)
12px above the dot's centre, so about 4px clear of the 16px dot.
-}
flagBesideX : Float
flagBesideX =
    flagPoleFoot - 600 - flagPoleFoot * 375 / flagPoleHeight


flagBesideY : Float
flagBesideY =
    (flagPoleHeight - 750 - 75) - 12 * flagUnitsPerPixel


{-| The flag's size on screen: how many of its units make a pixel. (At 62,
it's as big as it was when the map wasn't stretched, on desktop.)
-}
flagUnitsPerPixel : Float
flagUnitsPerPixel =
    62


type Flag
    = Start
    | Finish


flagPoleHeight : Float
flagPoleHeight =
    2100


{-| How far right of the pole's top its foot is: about 8 degrees of lean.
In the flag's own coordinates the top is at x = 0, so viewFlag moves the
whole flag this far left to stand the foot on the point.
-}
flagPoleFoot : Float
flagPoleFoot =
    300


{-| Where a point of the cloth goes, `u` along it (0 at the pole, 1200 at
the far edge) and `v` down it (0 at the top, 750 at the bottom). The wave
(flagWave) lifts or drops the whole height of the cloth alike at each `u`,
and the cloth leans with the pole: every point is further right the lower
it is, so both side edges slope like the pole.
-}
flagPoint : Float -> Float -> ( Float, Float )
flagPoint u v =
    ( u + flagPoleFoot * v / flagPoleHeight
    , -flagPoleHeight + v + flagWave u
    )


{-| An outline of the part of the cloth from `u0` to `u1` along it and `v0`
to `v1` down it, as polygon points: its top and bottom edges traced every
50 along, so they curve with the wave.
-}
flagShape : ( Float, Float ) -> ( Float, Float ) -> String
flagShape ( u0, u1 ) ( v0, v1 ) =
    let
        steps =
            round ((u1 - u0) / 50)

        us =
            List.map (\i -> u0 + (u1 - u0) * toFloat i / toFloat steps) (List.range 0 steps)

        point v u =
            let
                ( px, py ) =
                    flagPoint u v
            in
            String.fromFloat (toFloat (round (px * 10)) / 10) ++ "," ++ String.fromFloat (toFloat (round (py * 10)) / 10)
    in
    String.join " " (List.map (point v0) us ++ List.map (point v1) (List.reverse us))


{-| How far the wave moves the cloth up (negative) or down at `u` along it:
up 75 at u = 300, down 75 at u = 900.
-}
flagWave : Float -> Float
flagWave u =
    if u <= 600 then
        let
            t =
                u / 600
        in
        -300 * t * (1 - t)

    else
        let
            t =
                (u - 600) / 600
        in
        300 * t * (1 - t)


{-| The finish flag's black checks, 4 by 3 on the cloth (white under them),
black in the corner by the top of the pole.
-}
flagChecks : List (Svg Msg)
flagChecks =
    List.range 0 3
        |> List.concatMap
            (\col ->
                List.range 0 2
                    |> List.filter (\row -> modBy 2 (col + row) == 0)
                    |> List.map
                        (\row ->
                            Svg.polygon
                                [ SvgAttr.class "live-flag-check"
                                , SvgAttr.points
                                    (flagShape
                                        ( toFloat col * 300, toFloat (col + 1) * 300 )
                                        ( toFloat row * 250, toFloat (row + 1) * 250 )
                                    )
                                ]
                                []
                        )
            )


{-| A store's dot: the round end of a zero-length stroke, so it stays
round on the stretched map. Its size is its stroke width (live.html).
-}
viewStore : String -> Store -> Svg Msg
viewStore class store =
    let
        ( x, y ) =
            Projection.toMap { lat = store.lat, lon = store.lon }
    in
    Svg.path
        [ SvgAttr.class class
        , SvgAttr.d (dotPath ( x, y ))
        ]
        [ Svg.title [] [ Svg.text store.name ] ]


{-| What's clicked to focus a store: a bigger, invisible dot over its dot.
-}
viewStoreHit : Bool -> Store -> Svg Msg
viewStoreHit selected store =
    Svg.path
        [ SvgAttr.class "live-store-hit"
        , if selected then
            SvgAttr.id focusedDotId

          else
            SvgAttr.class "live-store-hit"
        , SvgAttr.d (dotPath (Projection.toMap { lat = store.lat, lon = store.lon }))
        , Svg.Events.onClick (Focus (FocusedStore store.id))
        ]
        [ Svg.title [] [ Svg.text store.name ] ]


{-| Posts made at one spot, newest first, and where (map coordinates): the
newest's place.
-}
type alias Spot =
    { at : ( Float, Float )
    , posts : List Post
    }


spotId : Spot -> String
spotId spot =
    List.head spot.posts |> Maybe.map .id |> Maybe.withDefault ""


{-| Posts within this many feet of each other share a pin: about a
block, so a McDonald's gets one pin, not a pile.
-}
spotRadius : Float
spotRadius =
    250


{-| The posts with a place, gathered into spots: each joins the first
spot (newest first) within spotRadius of it, or starts its own.
-}
postSpots : List Post -> List Spot
postSpots posts =
    posts
        |> List.filterMap (\post -> Maybe.map (\( lat, lon ) -> ( Projection.toMap { lat = lat, lon = lon }, post )) post.at)
        |> List.foldl
            (\( at, post ) spots ->
                joinFirstNear at post spots
                    |> Maybe.withDefault (spots ++ [ { at = at, posts = [ post ] } ])
            )
            []


{-| The spots with `post` added to the first within spotRadius of `at`;
Nothing if none is.
-}
joinFirstNear : ( Float, Float ) -> Post -> List Spot -> Maybe (List Spot)
joinFirstNear ( x, y ) post spots =
    case spots of
        [] ->
            Nothing

        spot :: rest ->
            let
                ( sx, sy ) =
                    spot.at
            in
            if (sx - x) ^ 2 + (sy - y) ^ 2 <= spotRadius ^ 2 then
                Just ({ spot | posts = spot.posts ++ [ post ] } :: rest)

            else
                Maybe.map ((::) spot) (joinFirstNear ( x, y ) post rest)


{-| A spot's pin on the map (see postDot), on its place.
-}
viewPostPin : Maybe Focused -> Spot -> Html Msg
viewPostPin focused spot =
    case boxPercent spot.at of
        Just ( left, top ) ->
            postDot focused
                (FocusedPosts (spotId spot))
                spot.posts
                ([ Attr.style "left" left, Attr.style "top" top ]
                    ++ (if focused == Just (FocusedPosts (spotId spot)) then
                            [ Attr.id focusedDotId ]

                        else
                            []
                       )
                )

        Nothing ->
            Html.text ""


{-| A spot's posts in a box beside its pin on the map (see postsBox): right
of it, or left near the map's right edge; down from it near the top, up
from it near the bottom.
-}
viewPostsFocus : Maybe Int -> Spot -> Html Msg
viewPostsFocus now spot =
    case boxPercent spot.at of
        Just ( left, top ) ->
            let
                percent text =
                    String.toFloat (String.dropRight 1 text) |> Maybe.withDefault 0
            in
            postsBox now
                (FocusedPosts (spotId spot))
                spot.posts
                [ ( "live-focus-left", percent left > 55 )
                , ( "live-focus-below", percent top < 30 )
                , ( "live-focus-above", percent top > 70 )
                ]
                [ Attr.style "left" left, Attr.style "top" top ]

        Nothing ->
            Html.text ""


{-| Posts' dot, on the map or the timeline: small and red (the newest
post's kind, or how many posts, in its tooltip). `attributes` place it.
Clicked, it opens `target`, the posts' box (see postsBox).
-}
postDot : Maybe Focused -> Focused -> List Post -> List (Html.Attribute Msg) -> Html Msg
postDot focused target posts attributes =
    case posts of
        newest :: _ ->
            let
                count =
                    List.length posts

                label =
                    if count == 1 then
                        "A " ++ postKind newest.content

                    else
                        String.fromInt count ++ " posts"
            in
            Html.button
                ([ Attr.classList
                    [ ( "live-post-pin", True )
                    , ( "live-post-pin-open", focused == Just target )
                    ]
                 , Attr.type_ "button"
                 , Attr.attribute "aria-label" label
                 , Attr.title label
                 , Events.onClick (Focus target)
                 ]
                    ++ attributes
                )
                []

        [] ->
            Html.text ""


postKind : PostContent -> String
postKind content =
    case content of
        Text _ ->
            "note"

        Photo _ _ ->
            "photo"

        Video _ _ ->
            "video"

        Voice _ ->
            "voice note"

        Pair _ ->
            "DoubleTake"


{-| Posts, newest first, in a box beside their dot: each as the feed shows
it, and when. Scrolls when there are many; × closes it (on a phone it's a
sheet over the dot, so the dot can't). Presses inside don't drag the map,
so video controls work. `classes` and `attributes` place it.
-}
postsBox : Maybe Int -> Focused -> List Post -> List ( String, Bool ) -> List (Html.Attribute Msg) -> Html Msg
postsBox now target posts classes attributes =
    Html.div
        ([ Attr.classList (( "live-focus", True ) :: ( "live-focus-posts", True ) :: classes)
         , Events.stopPropagationOn "mousedown" (Decode.succeed ( NoOp, True ))
         ]
            ++ attributes
        )
        (Html.button
            [ Attr.class "live-focus-close"
            , Attr.type_ "button"
            , Attr.attribute "aria-label" "Close"
            , Events.onClick (Focus target)
            ]
            [ Html.text "×" ]
            :: List.map
                (\post ->
                    Html.div [ Attr.class "live-focus-post" ]
                        [ viewPostContent (inBox post.content)
                        , case now of
                            Just ms ->
                                Html.span [ Attr.class "live-focus-when" ] [ Html.text (when ms post.ts) ]

                            Nothing ->
                                Html.text ""
                        ]
                )
                posts
        )


{-| The posts with a place, gathered into moments for the timeline, by
`timeOf` (see onWalkDay): each joins the newest moment (newest first) if
within momentMinutes and momentDegrees (of latitude) of its newest post,
or starts its own.
-}
postMoments : (Int -> Int) -> List Post -> List (List Post)
postMoments timeOf posts =
    let
        latitude post =
            Maybe.map Tuple.first post.at |> Maybe.withDefault 0
    in
    posts
        |> List.filter (\post -> post.at /= Nothing)
        |> List.sortBy (.ts >> timeOf >> negate)
        |> List.foldl
            (\post moments ->
                case moments of
                    (newest :: rest) :: others ->
                        if timeOf newest.ts - timeOf post.ts <= momentMinutes * 60000 && abs (latitude newest - latitude post) <= momentDegrees then
                            (newest :: rest ++ [ post ]) :: others

                        else
                            [ post ] :: moments

                    _ ->
                        [ post ] :: moments
            )
            []
        |> List.reverse


{-| Posts this close in time share a dot on the timeline: about a dot's
width on a phone, over a day's walk.
-}
momentMinutes : Int
momentMinutes =
    10


{-| And this close in latitude: about a dot's height (some 700 ft).
-}
momentDegrees : Float
momentDegrees =
    0.002


{-| The timeline's latitude axis (for posts; see Burndown.Marks): Manhattan
from the Battery (40.70°) to Inwood's northern tip (40.88°), north at the
top. `y` places a latitude, 0 (top) to 1 (bottom), held to the axis (a post
off the island sits at its edge); `axis` labels every 0.05°: "40.75°".
-}
latitudeScale : { y : Float -> Float, axis : List ( Float, String ) }
latitudeScale =
    let
        south =
            40.7

        north =
            40.88

        y lat =
            clamp 0 1 ((north - lat) / (north - south))

        label hundredths =
            String.fromInt (hundredths // 100) ++ "." ++ String.padLeft 2 '0' (String.fromInt (modBy 100 hundredths)) ++ "°"
    in
    { y = y
    , axis =
        List.range (ceiling (south * 20 - 1.0e-6)) (floor (north * 20 + 1.0e-6))
            |> List.map (\twentieths -> ( y (toFloat twentieths / 20), label (twentieths * 5) ))
    }


{-| A time moved to the same time of day (New York's) on the walk's day,
the day of the plan's first arrival: so on the timeline every post shows
at the time of day it was made, whatever the date. Unchanged without a
plan.
-}
onWalkDay : List Store -> Int -> Int
onWalkDay stores ts =
    let
        timeOfDay t =
            modBy 1440 (NewYorkTime.minuteOfWeek t) * 60000 + modBy 60000 t
    in
    case List.filterMap .arrive stores |> List.minimum of
        Just start ->
            start - timeOfDay start + timeOfDay ts

        Nothing ->
            ts


momentId : List Post -> String
momentId posts =
    List.head posts |> Maybe.map .id |> Maybe.withDefault ""


{-| A post as it fits a map box: a DoubleTake as its one cut video (the
side-by-side player needs the page's width).
-}
inBox : PostContent -> PostContent
inBox content =
    case content of
        Pair { cut } ->
            Video cut.url cut.posterUrl

        other ->
            other


{-| The focused store's box, beside its dot (right of it, or left near the
map's right edge): its name, and when I visited it (see visitNote) or, if I
haven't yet, when it next opens or closes (see hoursNote).
-}
viewFocus : Maybe Int -> Maybe Int -> Store -> Html Msg
viewFocus now visitedAt store =
    let
        note =
            case ( visitedAt, now ) of
                ( Just ts, _ ) ->
                    Just (visitNote now ts)

                ( Nothing, Just ms ) ->
                    hoursNote ms store

                ( Nothing, Nothing ) ->
                    Nothing
    in
    case boxPercent (Projection.toMap { lat = store.lat, lon = store.lon }) of
        Just ( left, top ) ->
            Html.div
                [ Attr.classList
                    [ ( "live-focus", True )
                    , ( "live-focus-left", (String.toFloat (String.dropRight 1 left) |> Maybe.withDefault 0) > 70 )
                    ]
                , Attr.style "left" left
                , Attr.style "top" top
                ]
                [ Html.strong [] [ Html.text store.name ]
                , case note of
                    Just text ->
                        Html.span [] [ Html.text text ]

                    Nothing ->
                        Html.text ""
                ]

        Nothing ->
            Html.text ""


{-| "Visited 5:34 AM", or with the date when that's more than 18 hours ago
(or the clock's not known yet): "Visited November 21, 5:34 AM EST".
-}
visitNote : Maybe Int -> Int -> String
visitNote now ts =
    case now of
        Just ms ->
            if ms - ts <= 18 * 3600000 then
                "Visited " ++ NewYorkTime.clock ts

            else
                "Visited " ++ NewYorkTime.format ts

        Nothing ->
            "Visited " ++ NewYorkTime.format ts


{-| When a store next closes, if it's open ("Open until 11:00 PM"), or next
opens, if it's closed ("Opens 5:00 AM"), from its weekly hours
(LiveMapData.openWindows). The day is added when that's more than 18 hours
off ("Opens Monday 6:00 AM"). Nothing for a store without hours.
-}
hoursNote : Int -> Store -> Maybe String
hoursNote ms store =
    let
        week =
            7 * 1440

        minute =
            NewYorkTime.minuteOfWeek ms

        at minutesAhead =
            let
                moment =
                    ms + minutesAhead * 60000
            in
            if minutesAhead > 18 * 60 then
                NewYorkTime.weekday moment ++ " " ++ NewYorkTime.clock moment

            else
                NewYorkTime.clock moment
    in
    Dict.get store.id LiveMapData.openWindows
        |> Maybe.andThen
            (\windows ->
                if windows == [ ( 0, week ) ] then
                    Just "Open 24 hours"

                else
                    case List.filter (\( from, to ) -> minute >= from && minute < to) windows of
                        ( _, to ) :: _ ->
                            let
                                -- Open past Sunday midnight: the week's first window carries on.
                                closes =
                                    if to == week then
                                        case List.filter (\( from, _ ) -> from == 0) windows of
                                            ( _, mondayTo ) :: _ ->
                                                week + mondayTo

                                            [] ->
                                                to

                                    else
                                        to
                            in
                            Just ("Open until " ++ at (closes - minute))

                        [] ->
                            let
                                opens =
                                    case List.filter (\( from, _ ) -> from > minute) windows |> List.map Tuple.first |> List.minimum of
                                        Just from ->
                                            Just from

                                        Nothing ->
                                            windows |> List.map (Tuple.first >> (+) week) |> List.minimum
                            in
                            opens |> Maybe.map (\from -> "Opens " ++ at (from - minute))
            )


{-| A zero-length line at a point, whose stroke's end caps make a dot. (A
hair's length, not none: some browsers skip a stroke of no length.)
-}
dotPath : ( Float, Float ) -> String
dotPath ( x, y ) =
    "M" ++ String.fromFloat x ++ "," ++ String.fromFloat y ++ " h0.01"


{-| The last position: a small red square with a white edge, the square
ends of zero-length strokes (see dotPath), so it stays square however the
map stretches.
-}
viewMe : ( Float, Float ) -> List (Svg Msg)
viewMe xy =
    [ Svg.path [ SvgAttr.class "live-me-edge", SvgAttr.d (dotPath xy) ] []
    , Svg.path [ SvgAttr.class "live-me", SvgAttr.d (dotPath xy) ] []
    ]


onMap : Maybe ( Float, Float ) -> Bool
onMap placed =
    case ( placed, stretchBox ) of
        ( Just ( x, y ), [ minX, minY, width, height ] ) ->
            x >= minX && x <= minX + width && y >= minY && y <= minY + height

        _ ->
            True


viewPosts : Model -> Html Msg
viewPosts model =
    case Maybe.map .response model.latest of
        Just response ->
            if List.isEmpty response.posts then
                Html.text ""

            else
                -- Keyed by post, so a video that's playing keeps playing
                -- when a newer post arrives above it. Each: its time of
                -- day (no date: it's the walk's day), the post, then likes
                -- and comments.
                Html.Keyed.ul [ Attr.class "live-posts" ]
                    (List.map
                        (\post ->
                            ( post.id
                            , Html.li [ Attr.class "live-post" ]
                                [ Html.p [ Attr.class "live-post-when" ] [ Html.text (NewYorkTime.clock post.ts) ]
                                , viewPostContent post.content
                                , Html.map GuestsMsg (Guests.viewPost (model.origin ++ pathOf model.route) post.id model.guests)
                                ]
                            )
                        )
                        response.posts
                    )

        Nothing ->
            Html.text ""


{-| Media from media.mctrot.nyc: a photo (its thumbnail or full size,
whichever is sharp on this screen) linking to its full size, and video and voice that only fetch their headers until played.
-}
viewPostContent : PostContent -> Html Msg
viewPostContent content =
    case content of
        Text text ->
            Html.p [ Attr.class "live-post-text" ] [ Html.text text ]

        Photo url thumbUrl ->
            Html.a [ Attr.href url, Attr.class "live-post-photo" ]
                [ Html.img
                    ([ Attr.src url
                     , Attr.alt "Photo"
                     , Attr.attribute "loading" "lazy"
                     ]
                        ++ (case thumbUrl of
                                -- Long sides 400 and 1600 px: the browser
                                -- takes the thumbnail only where it's sharp
                                -- (a small 1x screen); phones get full size.
                                Just thumb ->
                                    [ Attr.attribute "srcset" (thumb ++ " 400w, " ++ url ++ " 1600w")
                                    , Attr.attribute "sizes" "(min-width: 30rem) 28rem, calc(100vw - 32px)"
                                    ]

                                Nothing ->
                                    []
                           )
                    )
                    []
                ]

        Video url posterUrl ->
            Html.video
                ([ Attr.src url
                 , Attr.controls True
                 , Attr.attribute "preload" "metadata"
                 , Attr.attribute "playsinline" ""
                 , Attr.class "live-post-video"
                 ]
                    ++ (posterUrl |> Maybe.map (\p -> [ Attr.attribute "poster" p ]) |> Maybe.withDefault [])
                )
                []

        Pair { cut, first, second } ->
            let
                poster name clip =
                    clip.posterUrl |> Maybe.map (Attr.attribute name) |> Maybe.withDefault (Attr.class "")
            in
            Html.node "mctrot-pair"
                [ Attr.class "live-post-pair"
                , Attr.attribute "cut" cut.url
                , poster "cut-poster" cut
                , Attr.attribute "first" first.url
                , poster "first-poster" first
                , Attr.attribute "second" second.url
                , poster "second-poster" second
                ]
                []

        Voice url ->
            Html.audio
                [ Attr.src url
                , Attr.controls True
                , Attr.attribute "preload" "metadata"
                , Attr.class "live-post-voice"
                ]
                []
