port module Radio exposing (Flags, Model, Msg, init, subscriptions, update, view)

{-| The radio player in /live's top-right corner: play and stop McTrot
radio (recorder/host/radio.nix), set the volume, and find its links for
other players.

Elm can't drive audio itself, so it sends commands out through a port
(`radioOut`) to a few lines of JavaScript in live.html that own an
`<audio>` element, and hears back what the audio is doing (`radioIn`).

-}

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Events
import Json.Decode as Decode
import Json.Encode as Encode


port radioOut : Encode.Value -> Cmd msg


port radioIn : (Decode.Value -> msg) -> Sub msg


{-| The station: the stream the page plays, and playlists pointing at
it for players that want one.
-}
stream : String
stream =
    "https://radio.mctrot.nyc/live.mp3"


links : List ( String, String )
links =
    [ ( "Stream (MP3)", stream )
    , ( "Playlist (M3U)", "https://radio.mctrot.nyc/live.m3u" )
    , ( "Playlist (PLS)", "https://radio.mctrot.nyc/live.pls" )
    ]


{-| `volumeAdjustable` is False on iPhones and iPads: there the hardware
buttons set the volume, and pages can't.
-}
type alias Flags =
    { volumeAdjustable : Bool }


type State
    = Stopped
    | Connecting
    | Playing
    | Failed String


type alias Model =
    { volumeAdjustable : Bool
    , state : State
    , volume : Float
    , showingLinks : Bool
    }


init : Flags -> Model
init flags =
    { volumeAdjustable = flags.volumeAdjustable
    , state = Stopped
    , volume = 0.8
    , showingLinks = False
    }


type Msg
    = Play
    | Stop
    | SetVolume Float
    | ToggleLinks
    | FromAudio Decode.Value


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Play ->
            ( { model | state = Connecting }, play model )

        Stop ->
            ( { model | state = Stopped }, command "stop" [] )

        SetVolume volume ->
            ( { model | volume = volume }, command "volume" [ ( "volume", Encode.float volume ) ] )

        ToggleLinks ->
            ( { model | showingLinks = not model.showingLinks }, Cmd.none )

        FromAudio value ->
            case Decode.decodeValue audioEvent value of
                Ok event ->
                    ( { model | state = afterEvent event model.state }, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )


play : Model -> Cmd Msg
play model =
    command "play" [ ( "url", Encode.string stream ), ( "volume", Encode.float model.volume ) ]


command : String -> List ( String, Encode.Value ) -> Cmd Msg
command name fields =
    radioOut (Encode.object (( "command", Encode.string name ) :: fields))


type AudioEvent
    = Started
    | Buffering
    | Paused
    | Ended
    | Error String


audioEvent : Decode.Decoder AudioEvent
audioEvent =
    Decode.field "event" Decode.string
        |> Decode.andThen
            (\event ->
                case event of
                    "playing" ->
                        Decode.succeed Started

                    "waiting" ->
                        Decode.succeed Buffering

                    "paused" ->
                        Decode.succeed Paused

                    "ended" ->
                        Decode.succeed Ended

                    "error" ->
                        Decode.map Error (Decode.field "message" Decode.string)

                    other ->
                        Decode.fail other
            )


afterEvent : AudioEvent -> State -> State
afterEvent event state =
    case ( event, state ) of
        -- Late news from a stream already stopped.
        ( _, Stopped ) ->
            Stopped

        ( Started, _ ) ->
            Playing

        ( Buffering, _ ) ->
            Connecting

        -- Paused from outside the page: the lock screen, headphones.
        ( Paused, _ ) ->
            Stopped

        ( Ended, _ ) ->
            Failed "The stream ended."

        ( Error message, _ ) ->
            Failed message


subscriptions : Model -> Sub Msg
subscriptions _ =
    radioIn FromAudio


view : Model -> Html Msg
view model =
    let
        on =
            model.state /= Stopped

        status =
            case model.state of
                Stopped ->
                    "Off"

                Connecting ->
                    "Tuning in…"

                Playing ->
                    "On"

                Failed message ->
                    message
    in
    Html.aside [ Attr.class "radio", Attr.attribute "aria-label" "Radio" ]
        [ Html.div [ Attr.class "radio-bar" ]
            [ Html.button
                [ Attr.class "radio-play"
                , Attr.type_ "button"
                , Events.onClick
                    (if on then
                        Stop

                     else
                        Play
                    )
                , Attr.attribute "aria-label"
                    (if on then
                        "Stop the radio"

                     else
                        "Play the radio"
                    )
                ]
                [ Html.text
                    (if on then
                        "■"

                     else
                        "▶"
                    )
                ]
            , Html.div [ Attr.class "radio-info" ]
                [ Html.span [ Attr.class "radio-name" ] [ Html.text "Radio" ]
                , Html.span
                    [ Attr.class "radio-status"
                    , Attr.classList [ ( "radio-problem", isFailed model.state ) ]
                    , Attr.attribute "aria-live" "polite"
                    ]
                    [ Html.text status ]
                ]
            , if model.volumeAdjustable then
                Html.input
                    [ Attr.type_ "range"
                    , Attr.class "radio-volume"
                    , Attr.min "0"
                    , Attr.max "1"
                    , Attr.step "0.05"
                    , Attr.value (String.fromFloat model.volume)
                    , Attr.attribute "aria-label" "Volume"
                    , Events.onInput (String.toFloat >> Maybe.withDefault model.volume >> SetVolume)
                    ]
                    []

              else
                Html.text ""
            , Html.button
                [ Attr.class "radio-links-button"
                , Attr.type_ "button"
                , Attr.attribute "aria-expanded"
                    (if model.showingLinks then
                        "true"

                     else
                        "false"
                    )
                , Events.onClick ToggleLinks
                ]
                [ Html.text "Links" ]
            ]
        , if model.showingLinks then
            viewLinks

          else
            Html.text ""
        ]


{-| McTrot radio's addresses, for VLC, Apple Music and radio apps.
-}
viewLinks : Html Msg
viewLinks =
    Html.dl [ Attr.class "radio-links" ]
        (List.concatMap
            (\( label, url ) ->
                [ Html.dt [] [ Html.text label ]
                , Html.dd [] [ Html.a [ Attr.href url ] [ Html.text url ] ]
                ]
            )
            links
        )


isFailed : State -> Bool
isFailed state =
    case state of
        Failed _ ->
            True

        _ ->
            False
