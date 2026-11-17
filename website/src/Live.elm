port module Live exposing (main)

{-| mctrot.nyc/live: where I am during a McTrot attempt.

Polls the recorder's `GET /live` (recorder/api/src/live.ts; contract in
recorder/api/live.schema.json) every 15 seconds.

One program for five addresses, routed here (Netlify serves live.html for
all of them; website/_redirects):

  - /live: everything on one page, as it has been
  - /live/map, /live/blog, /live/timeline, /live/stats: one view each,
    taking over the page

All five share the title, the radio, the tab switcher and the footer.
Switching tabs doesn't reload the page, so the radio keeps playing.

Elm runs in its own element (Browser.element), not over the whole page
(Browser.application): browser extensions add things to <body>, and an
application, which owns the body, crashes when they do. So the address
is handled here through two ports and a few lines in live.html:
`navigate` (pushState) and `pathChanged` (Back and Forward).

-}

import Browser
import Browser.Dom
import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Events
import Html.Keyed
import Http
import Json.Decode as Decode exposing (Decoder)
import MctrotMapData
import NewYorkTime
import Projection
import Radio
import Svg exposing (Svg)
import Svg.Attributes as SvgAttr
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
    }



-- /live RESPONSE (see recorder/api/live.schema.json)


type alias LiveResponse =
    { serverTs : Int
    , position : Maybe Position
    , attempt : Maybe Attempt
    , stores : List Store
    , track : List (List ( Float, Float ))
    , visits : List Visit
    , posts : List Post
    , weather : Maybe Weather
    , sun : Sun
    , sky : List SkySquare
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


type alias Store =
    { id : String
    , name : String
    , lat : Float
    , lon : Float
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
    Decode.map3 Post
        (Decode.field "id" Decode.string)
        (Decode.field "ts" Decode.int)
        (Decode.field "type" Decode.string |> Decode.andThen postContentDecoder)


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
    Decode.map4 Store
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "lat" Decode.float)
        (Decode.field "lon" Decode.float)


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
    , route : Route
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
    in
    ( { api = flags.api
      , latest = Nothing
      , failing = False
      , now = Nothing
      , radio = Radio.init flags.radio
      , route = route
      }
    , Cmd.batch [ fetch flags.api, Task.perform Tick Time.now, setTitle (titleOf route) ]
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
    | NoOp


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        -- A tab (or the title) clicked: switch views without reloading,
        -- so the radio keeps playing.
        Navigate route ->
            ( { model | route = route }
            , Cmd.batch
                [ navigate { path = pathOf route, title = titleOf route }
                , if route == TimelineTab then
                    scrollTimelineToNow

                  else
                    Cmd.none
                ]
            )

        -- Back or Forward.
        PathChanged path ->
            let
                route =
                    routeFromPath path
            in
            ( { model | route = route }
            , Cmd.batch
                [ setTitle (titleOf route)
                , if route == TimelineTab then
                    scrollTimelineToNow

                  else
                    Cmd.none
                ]
            )

        NoOp ->
            ( model, Cmd.none )

        RadioMsg radioMsg ->
            Radio.update radioMsg model.radio
                |> Tuple.mapBoth (\radio -> { model | radio = radio }) (Cmd.map RadioMsg)

        Poll ->
            ( model, fetch model.api )

        Got (Ok response) ->
            ( model, Task.perform (Received response) Time.now )

        Got (Err _) ->
            -- Keep showing the last position; the next poll retries.
            ( { model | failing = True }, Cmd.none )

        Received response at ->
            ( { model | latest = Just (Fetched response at), failing = False, now = Just at }
              -- The first data on the timeline: start at the newest end.
            , if model.route == TimelineTab && model.latest == Nothing then
                scrollTimelineToNow

              else
                Cmd.none
            )

        Tick now ->
            ( { model | now = Just now }, Cmd.none )


{-| The timeline runs oldest to newest, left to right: open it at the
newest end.
-}
scrollTimelineToNow : Cmd Msg
scrollTimelineToNow =
    Browser.Dom.getViewportOf "timeline"
        |> Task.andThen (\v -> Browser.Dom.setViewportOf "timeline" v.scene.width 0)
        |> Task.attempt (\_ -> NoOp)


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
        ]



-- VIEW


view : Model -> Html Msg
view model =
    Html.div [ Attr.class ("app page-" ++ routeName model.route) ]
        [ -- Title, radio and view switcher stay at the top as the page
          -- scrolls (live.html, .app-top).
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
        , viewFooter
        ]


viewHeader : Model -> Html Msg
viewHeader model =
    Html.header [ Attr.class "app-header" ]
        [ Html.div [ Attr.class "app-title" ]
            [ Html.h1 [] [ link Overview [] [ Html.text "McTROT 5" ] ]
            , Html.p [ Attr.class "app-subtitle" ] [ Html.text "EATING AT EVERY McDONALD’S IN MANHATTAN ON ONE WALK" ]
            ]
        , Html.map RadioMsg (Radio.view model.radio)
        ]


{-| The views, as a row of radio-button-style segments: links, so each
has its own address, with the current one marked.
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


viewFooter : Html Msg
viewFooter =
    Html.footer [ Attr.class "app-footer" ]
        [ Html.a [ Attr.href "/" ] [ Html.text "mctrot.nyc" ]
        , Html.span [ Attr.class "app-footer-radio" ]
            (Html.text "Radio: "
                :: (Radio.links
                        |> List.map (\( label, url ) -> Html.a [ Attr.href url ] [ Html.text label ])
                        |> List.intersperse (Html.text " · ")
                   )
            )
        ]


{-| Plain /live: everything on one page, as it was before the tabs.
-}
viewOverview : Model -> List (Html Msg)
viewOverview model =
    let
        response =
            Maybe.map .response model.latest
    in
    [ Html.div [ Attr.class "live" ]
        [ viewStatus model
        , Html.p [ Attr.class "live-visits" ] [ Html.text (visitsLine model) ]
        , viewWeather model
        , viewSky response
        , viewMap response
        , viewSun response
        , viewPosts model
        ]
    ]


viewStatus : Model -> Html Msg
viewStatus model =
    Html.p [ Attr.class "live-status", Attr.attribute "aria-live" "polite" ] [ Html.text (status model) ]


{-| The map, filling the page. (Zooming comes in a later pass.)
-}
viewMapTab : Model -> List (Html Msg)
viewMapTab model =
    [ viewStatus model
    , viewMap (Maybe.map .response model.latest)
    ]


{-| The posts, newest first, scrolling down the page.
-}
viewBlogTab : Model -> List (Html Msg)
viewBlogTab model =
    [ viewPosts model ]


{-| Posts and check-ins in time order, oldest to newest, scrolling
sideways.
-}
viewTimelineTab : Model -> List (Html Msg)
viewTimelineTab model =
    case ( Maybe.map .response model.latest, serverNow model ) of
        ( Just response, Just now ) ->
            let
                storeName id =
                    List.filter (\store -> store.id == id) response.stores
                        |> List.head
                        |> Maybe.map .name
                        |> Maybe.withDefault "a McDonald’s"

                checkIn visit =
                    let
                        what =
                            case visit.match of
                                Matched id ->
                                    "Checked in at " ++ storeName id

                                Pending ->
                                    "Checked in (finding which McDonald’s…)"

                                Unmatched ->
                                    "Checked in (no McDonald’s nearby)"
                    in
                    ( visit.tapTs
                    , "visit-" ++ String.fromInt visit.tapTs
                    , Html.p [ Attr.class "timeline-checkin" ] [ Html.text ("📍 " ++ what) ]
                    )

                items =
                    (List.map (\post -> ( post.ts, post.id, viewPostContent post.content )) response.posts
                        ++ List.map checkIn response.visits
                    )
                        |> List.sortBy (\( ts, _, _ ) -> ts)
            in
            if List.isEmpty items then
                [ Html.p [ Attr.class "tab-empty" ] [ Html.text "Nothing yet." ] ]

            else
                [ Html.Keyed.ol [ Attr.id "timeline", Attr.class "timeline" ]
                    (List.map
                        (\( ts, key, content ) ->
                            ( key
                            , Html.li [ Attr.class "timeline-item" ]
                                [ Html.p [ Attr.class "timeline-when" ] [ Html.text (when now ts) ]
                                , content
                                ]
                            )
                        )
                        items
                    )
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
        [ cell "Attempt" [ Html.p [] [ Html.text (visitsLine model) ] ]
        , cell "Position" [ Html.p [] [ Html.text (status model) ] ]
        , cell "Weather" [ viewWeather model ]
        , cell "Sky" [ viewSky response ]
        , cell "Sun" [ viewSun response ]
        ]
    ]


{-| "54°F, clear, feels like 47°F. Wind 9 mph from the NW, gusts 12 mph."
-}
viewWeather : Model -> Html Msg
viewWeather model =
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
                [ Html.text (capitalize first ++ ". " ++ wind)
                , Html.span [ Attr.class "live-weather-when" ]
                    [ Html.text (" " ++ w.place ++ ", " ++ when now w.observedAt ++ ".") ]
                ]

        _ ->
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


visitsLine : Model -> String
visitsLine model =
    case ( Maybe.map .response model.latest, serverNow model ) of
        ( Just response, Just now ) ->
            case response.attempt of
                Nothing ->
                    "No attempt yet."

                Just attempt ->
                    let
                        count status_ =
                            List.length (List.filter (.match >> status_) response.visits)

                        matched =
                            count isMatched

                        extra label n =
                            if n > 0 then
                                " · " ++ String.fromInt n ++ " " ++ label

                            else
                                ""

                        visits =
                            "Visits "
                                ++ String.fromInt matched
                                ++ " / "
                                ++ String.fromInt (List.length response.stores)
                                ++ extra "checking in" (count ((==) Pending))
                                ++ extra "unmatched" (count ((==) Unmatched))
                    in
                    case attempt.endedAt of
                        Nothing ->
                            "On the road for " ++ duration (now - attempt.startedAt) ++ ". " ++ visits ++ "."

                        Just endedAt ->
                            "Last attempt took " ++ duration (endedAt - attempt.startedAt) ++ ". " ++ visits ++ "."

        _ ->
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


viewMap : Maybe LiveResponse -> Html Msg
viewMap response =
    let
        position =
            Maybe.andThen .position response

        placed =
            Maybe.map (\p -> Projection.toMap { lat = p.lat, lon = p.lon }) position

        stores =
            Maybe.map .stores response |> Maybe.withDefault []

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

        ( done, todo ) =
            List.partition (\s -> List.member s.id visited) stores

        track =
            Maybe.map .track response |> Maybe.withDefault []
    in
    Html.div [ Attr.class "live-map" ]
        [ Svg.svg
            [ SvgAttr.viewBox MctrotMapData.mapViewBox
            , SvgAttr.class "live-map-svg"
            , Attr.attribute "role" "img"
            , Attr.attribute "aria-label" "Map of Manhattan with every store, the ones visited, the path I've walked and my last position"
            ]
            (Svg.path [ SvgAttr.class "borough", SvgAttr.d MctrotMapData.boroughPath ] []
                :: List.map viewTrack track
                ++ List.map (viewStore "live-store" "120") todo
                ++ List.map (viewStore "live-store live-store-visited" "200") done
                ++ (placed |> Maybe.map (\xy -> [ viewMe xy ]) |> Maybe.withDefault [])
            )
        , if placed /= Nothing && not (onMap placed) then
            Html.p [ Attr.class "live-note" ] [ Html.text "The last position is off this map." ]

          else
            Html.text ""
        ]


{-| One stretch of the path walked (the server splits it where GPS was lost).
-}
viewTrack : List ( Float, Float ) -> Svg Msg
viewTrack segment =
    Svg.polyline
        [ SvgAttr.class "live-track"
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


viewStore : String -> String -> Store -> Svg Msg
viewStore class radius store =
    let
        ( x, y ) =
            Projection.toMap { lat = store.lat, lon = store.lon }
    in
    Svg.circle
        [ SvgAttr.class class
        , SvgAttr.cx (String.fromFloat x)
        , SvgAttr.cy (String.fromFloat y)
        , SvgAttr.r radius
        ]
        [ Svg.title [] [ Svg.text store.name ] ]


viewMe : ( Float, Float ) -> Svg Msg
viewMe ( x, y ) =
    Svg.circle
        [ SvgAttr.class "live-me"
        , SvgAttr.cx (String.fromFloat x)
        , SvgAttr.cy (String.fromFloat y)
        , SvgAttr.r "350"
        ]
        []


onMap : Maybe ( Float, Float ) -> Bool
onMap placed =
    case ( placed, viewBoxNumbers ) of
        ( Just ( x, y ), [ minX, minY, width, height ] ) ->
            x >= minX && x <= minX + width && y >= minY && y <= minY + height

        _ ->
            True


viewBoxNumbers : List Float
viewBoxNumbers =
    MctrotMapData.mapViewBox |> String.words |> List.filterMap String.toFloat


viewPosts : Model -> Html Msg
viewPosts model =
    case ( Maybe.map .response model.latest, serverNow model ) of
        ( Just response, Just now ) ->
            if List.isEmpty response.posts then
                Html.text ""

            else
                -- Keyed by post, so a video that's playing keeps playing
                -- when a newer post arrives above it.
                Html.Keyed.ul [ Attr.class "live-posts" ]
                    (List.map
                        (\post ->
                            ( post.id
                            , Html.li [ Attr.class "live-post" ]
                                [ viewPostContent post.content
                                , Html.p [ Attr.class "live-post-when" ] [ Html.text (when now post.ts) ]
                                ]
                            )
                        )
                        response.posts
                    )

        _ ->
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
