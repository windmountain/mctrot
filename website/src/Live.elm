module Live exposing (main)

{-| mctrot.nyc/live: where I am during a McTrot attempt.

Polls the recorder's `GET /live` (recorder/api/src/live.ts; contract in
recorder/api/live.schema.json) every 15 seconds and draws the latest
position on the site's Manhattan map.

-}

import Array
import Browser
import Html exposing (Html)
import Html.Attributes as Attr
import Http
import Json.Decode as Decode exposing (Decoder)
import MctrotMapData
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
    }


type alias Position =
    { ts : Int
    , lat : Float
    , lon : Float
    , accuracy : Maybe Float
    }


liveDecoder : Decoder LiveResponse
liveDecoder =
    Decode.map2 LiveResponse
        (Decode.field "serverTs" Decode.int)
        (Decode.field "position" (Decode.nullable positionDecoder))


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
    Html.div [ Attr.class "live" ]
        [ Html.p [ Attr.class "live-home" ] [ Html.a [ Attr.href "/" ] [ Html.text "McTrot" ] ]
        , Html.h1 [] [ Html.text "Live" ]
        , Html.p [ Attr.class "live-status", Attr.attribute "aria-live" "polite" ]
            [ Html.text (status model) ]
        , viewMap (Maybe.andThen (.response >> .position) model.latest)
        ]


status : Model -> String
status model =
    let
        problem =
            if model.failing then
                " Can’t reach the recorder; retrying."

            else
                ""
    in
    case model.latest of
        Nothing ->
            if model.failing then
                "Can’t reach the recorder; retrying."

            else
                "Connecting…"

        Just { response, receivedAt } ->
            case response.position of
                Nothing ->
                    "No position yet." ++ problem

                Just position ->
                    let
                        sinceReceived =
                            case model.now of
                                Just now ->
                                    Time.posixToMillis now - Time.posixToMillis receivedAt

                                Nothing ->
                                    0

                        ageMs =
                            response.serverTs - position.ts + max 0 sinceReceived
                    in
                    "Last position " ++ ago ageMs ++ "." ++ problem


ago : Int -> String
ago ms =
    let
        seconds =
            max 0 ms // 1000
    in
    if seconds < 60 then
        String.fromInt seconds ++ " s ago"

    else if seconds < 3600 then
        String.fromInt (seconds // 60) ++ " min ago"

    else if seconds < 2 * 86400 then
        String.fromInt (seconds // 3600) ++ " h ago"

    else
        String.fromInt (seconds // 86400) ++ " days ago"


viewMap : Maybe Position -> Html Msg
viewMap position =
    let
        placed =
            Maybe.map (\p -> Projection.toMap { lat = p.lat, lon = p.lon }) position
    in
    Html.div [ Attr.class "live-map" ]
        [ Svg.svg
            [ SvgAttr.viewBox MctrotMapData.mapViewBox
            , SvgAttr.class "live-map-svg"
            , Attr.attribute "role" "img"
            , Attr.attribute "aria-label" "Map of Manhattan with every McDonald’s and my last position"
            ]
            (Svg.path [ SvgAttr.class "borough", SvgAttr.d MctrotMapData.boroughPath ] []
                :: List.map viewStore (Array.toList MctrotMapData.locationCoords)
                ++ (placed |> Maybe.map (\xy -> [ viewMe xy ]) |> Maybe.withDefault [])
            )
        , if placed /= Nothing && not (onMap placed) then
            Html.p [ Attr.class "live-note" ] [ Html.text "The last position is off this map." ]

          else
            Html.text ""
        ]


viewStore : ( Float, Float ) -> Svg Msg
viewStore ( x, y ) =
    Svg.circle
        [ SvgAttr.class "live-store"
        , SvgAttr.cx (String.fromFloat x)
        , SvgAttr.cy (String.fromFloat y)
        , SvgAttr.r "120"
        ]
        []


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

