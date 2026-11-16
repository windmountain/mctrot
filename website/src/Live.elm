module Live exposing (main)

{-| mctrot.nyc/live: where I am during a McTrot attempt.

Polls the recorder's `GET /live` (recorder/api/src/live.ts; contract in
recorder/api/live.schema.json) every 15 seconds and draws the latest
position and the path walked on the site's Manhattan map.

-}

import Browser
import Html exposing (Html)
import Html.Attributes as Attr
import Html.Keyed
import Http
import Json.Decode as Decode exposing (Decoder)
import MctrotMapData
import NewYorkTime
import Projection
import Svg exposing (Svg)
import Svg.Attributes as SvgAttr
import Task
import Time


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }


{-| `api`: the recorder's base URL, e.g. "https://api.mctrot.nyc".
-}
type alias Flags =
    { api : String }



-- /live RESPONSE (see recorder/api/live.schema.json)


type alias LiveResponse =
    { serverTs : Int
    , position : Maybe Position
    , attempt : Maybe Attempt
    , stores : List Store
    , track : List (List ( Float, Float ))
    , visits : List Visit
    , posts : List Post
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


{-| A Visit tap, matched to a store by GPS on the server.
-}
type Visit
    = Matched String
    | Pending
    | Unmatched


liveDecoder : Decoder LiveResponse
liveDecoder =
    Decode.map7 LiveResponse
        (Decode.field "serverTs" Decode.int)
        (Decode.field "position" (Decode.nullable positionDecoder))
        (Decode.field "attempt" (Decode.nullable attemptDecoder))
        (Decode.field "stores" (Decode.list storeDecoder))
        (Decode.field "track" (Decode.list (Decode.list latLonDecoder)))
        (Decode.field "visits" (Decode.list visitDecoder))
        (Decode.field "posts" (Decode.list postDecoder))


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
    ( { api = flags.api, latest = Nothing, failing = False, now = Nothing }
    , Cmd.batch [ fetch flags.api, Task.perform Tick Time.now ]
    )



-- UPDATE


type Msg
    = Poll
    | Got (Result Http.Error LiveResponse)
    | Received LiveResponse Time.Posix
    | Tick Time.Posix


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Poll ->
            ( model, fetch model.api )

        Got (Ok response) ->
            ( model, Task.perform (Received response) Time.now )

        Got (Err _) ->
            -- Keep showing the last position; the next poll retries.
            ( { model | failing = True }, Cmd.none )

        Received response at ->
            ( { model | latest = Just (Fetched response at), failing = False, now = Just at }
            , Cmd.none
            )

        Tick now ->
            ( { model | now = Just now }, Cmd.none )


fetch : String -> Cmd Msg
fetch api =
    Http.get { url = api ++ "/live", expect = Http.expectJson Got liveDecoder }


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ -- Overland sends every 30 s, so polling faster shows nothing new.
          Time.every 15000 (\_ -> Poll)
        , Time.every 1000 Tick
        ]



-- VIEW


view : Model -> Html Msg
view model =
    let
        response =
            Maybe.map .response model.latest
    in
    Html.div [ Attr.class "live" ]
        [ Html.p [ Attr.class "live-home" ] [ Html.a [ Attr.href "/" ] [ Html.text "McTrot" ] ]
        , Html.h1 [] [ Html.text "Live" ]
        , Html.p [ Attr.class "live-status", Attr.attribute "aria-live" "polite" ]
            [ Html.text (status model) ]
        , Html.p [ Attr.class "live-visits" ] [ Html.text (visitsLine model) ]
        , viewMap response
        , viewPosts model
        ]


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
                            List.length (List.filter status_ response.visits)

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


isMatched : Visit -> Bool
isMatched visit =
    case visit of
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
                        case v of
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
