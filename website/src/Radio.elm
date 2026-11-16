port module Radio exposing (Flags, Model, Msg, init, subscriptions, update, view)

{-| The radio player in /live's top-right corner: play and stop an
internet radio stream, set the volume, and change the station.

Elm can't drive audio itself, so it sends commands out through a port
(`radioOut`) to a few lines of JavaScript in live.html that own an
`<audio>` element, and hears back what the audio is doing (`radioIn`).
The station's URL is remembered in the browser (localStorage, kept by
that JavaScript).

What plays: a direct audio stream over HTTP(S), MP3 or AAC, as Icecast
and Shoutcast serve. Not playlists (.pls, .m3u), which point at a stream
rather than being one. HLS (.m3u8) plays in Safari only.

-}

import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Events
import Json.Decode as Decode
import Json.Encode as Encode


port radioOut : Encode.Value -> Cmd msg


port radioIn : (Decode.Value -> msg) -> Sub msg


type alias Flags =
    { url : String
    , defaultUrl : String

    -- False on iPhones and iPads: there the hardware buttons set the
    -- volume, and pages can't.
    , volumeAdjustable : Bool
    }


type State
    = Stopped
    | Connecting
    | Playing
    | Failed String


type alias Model =
    { url : String
    , defaultUrl : String
    , volumeAdjustable : Bool
    , state : State
    , volume : Float

    -- The station field, while it's open: what's typed, and why it was refused.
    , editing : Maybe { text : String, problem : Maybe String }
    }


init : Flags -> Model
init flags =
    { url = flags.url
    , defaultUrl = flags.defaultUrl
    , volumeAdjustable = flags.volumeAdjustable
    , state = Stopped
    , volume = 0.8
    , editing = Nothing
    }


type Msg
    = Play
    | Stop
    | SetVolume Float
    | OpenStation
    | TypeStation String
    | SaveStation
    | UseDefault
    | CloseStation
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

        OpenStation ->
            ( { model | editing = Just { text = model.url, problem = Nothing } }, Cmd.none )

        TypeStation text ->
            ( { model | editing = Maybe.map (\e -> { e | text = text, problem = Nothing }) model.editing }, Cmd.none )

        SaveStation ->
            case Maybe.map (.text >> String.trim) model.editing of
                Just text ->
                    case checkUrl text of
                        Ok url ->
                            changeStation url model

                        Err problem ->
                            ( { model | editing = Just { text = text, problem = Just problem } }, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        UseDefault ->
            changeStation model.defaultUrl model

        CloseStation ->
            ( { model | editing = Nothing }, Cmd.none )

        FromAudio value ->
            case Decode.decodeValue audioEvent value of
                Ok event ->
                    ( { model | state = afterEvent event model.state }, Cmd.none )

                Err _ ->
                    ( model, Cmd.none )


{-| Saves the station; if the radio was on, it switches over.
-}
changeStation : String -> Model -> ( Model, Cmd Msg )
changeStation url model =
    let
        changed =
            { model | url = url, editing = Nothing }

        on =
            model.state /= Stopped
    in
    ( if on then
        { changed | state = Connecting }

      else
        { changed | state = Stopped }
    , Cmd.batch
        [ command "save"
            [ ( "url"
              , if url == model.defaultUrl then
                    Encode.null

                else
                    Encode.string url
              )
            ]
        , if on then
            play changed

          else
            Cmd.none
        ]
    )


checkUrl : String -> Result String String
checkUrl text =
    if String.startsWith "https://" text || String.startsWith "http://" text then
        if String.contains " " text then
            Err "That has a space in it; a URL can’t."

        else
            Ok text

    else
        Err "That doesn’t start with https://."


play : Model -> Cmd Msg
play model =
    command "play" [ ( "url", Encode.string model.url ), ( "volume", Encode.float model.volume ) ]


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
                [ Attr.class "radio-station-button"
                , Attr.type_ "button"
                , Attr.attribute "aria-expanded"
                    (if model.editing == Nothing then
                        "false"

                     else
                        "true"
                    )
                , Events.onClick
                    (if model.editing == Nothing then
                        OpenStation

                     else
                        CloseStation
                    )
                ]
                [ Html.text "Station" ]
            ]
        , case model.editing of
            Just editing ->
                viewStation model editing

            Nothing ->
                Html.text ""
        ]


viewStation : Model -> { text : String, problem : Maybe String } -> Html Msg
viewStation model editing =
    Html.form [ Attr.class "radio-station", Events.onSubmit SaveStation ]
        [ Html.label [ Attr.for "radio-url" ] [ Html.text "Stream URL" ]
        , Html.input
            [ Attr.id "radio-url"
            , Attr.type_ "url"
            , Attr.value editing.text
            , Attr.placeholder "https://example.com/stream.mp3"
            , Attr.attribute "autocomplete" "off"
            , Attr.attribute "autocapitalize" "off"
            , Attr.spellcheck False
            , Events.onInput TypeStation
            ]
            []
        , case editing.problem of
            Just problem ->
                Html.p [ Attr.class "radio-problem" ] [ Html.text problem ]

            Nothing ->
                Html.text ""
        , Html.p [ Attr.class "radio-hint" ]
            [ Html.text "A direct audio stream over HTTPS: MP3 or AAC, as Icecast and Shoutcast serve. Not a playlist (.pls, .m3u): open one and use the stream URL inside it. HLS (.m3u8) plays in Safari only. On this https page, an http:// stream is blocked." ]
        , Html.div [ Attr.class "radio-station-actions" ]
            [ Html.button [ Attr.type_ "submit" ] [ Html.text "Save" ]
            , if model.url /= model.defaultUrl then
                Html.button [ Attr.type_ "button", Events.onClick UseDefault ] [ Html.text "Use McTrot radio" ]

              else
                Html.text ""
            , Html.button [ Attr.type_ "button", Events.onClick CloseStation ] [ Html.text "Cancel" ]
            ]
        ]


isFailed : State -> Bool
isFailed state =
    case state of
        Failed _ ->
            True

        _ ->
            False
