port module Radio exposing (Flags, Model, Msg, NowPlaying, OnAir, announce, init, links, nowPlaying, onAirDecoder, subscriptions, update, view)

{-| The radio player in /live's top-right corner: play and stop McTrot
radio (recorder/host/radio.nix), set the volume, and find its links for
other players.

Elm can't drive audio itself, so it sends commands out through a port
(`radioOut`) to a few lines of JavaScript in live.html that own an
`<audio>` element, and hears back what the audio is doing (`radioIn`).

What's on comes from the recorder (/live's `radio`, from the same program
Liquidsoap plays: recorder/station/program.liq), shown in the player and
told to the phone's lock screen (`announce`).

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


{-| What's on now, and what's on next and when, as /live has it.
-}
type alias OnAir =
    { current : Slot
    , next : Maybe Slot
    }


{-| One thing on the radio: a track, a break, or the holding loop. `from`
and `to` are ms since the epoch; Nothing when it's been on since before
the program says, or is on from now on.
-}
type alias Slot =
    { artist : String
    , title : String
    , album : Maybe String
    , year : Maybe String
    , from : Maybe Int
    , to : Maybe Int
    }


type alias NowPlaying =
    Slot


onAirDecoder : Decode.Decoder OnAir
onAirDecoder =
    let
        optional name =
            Decode.oneOf [ Decode.field name (Decode.nullable Decode.string), Decode.succeed Nothing ]

        slot =
            Decode.map6 Slot
                (Decode.field "artist" Decode.string)
                (Decode.field "title" Decode.string)
                (optional "album")
                (optional "year")
                (Decode.field "from" (Decode.nullable Decode.int))
                (Decode.field "to" (Decode.nullable Decode.int))
    in
    Decode.map2 OnAir
        (Decode.field "current" slot)
        (Decode.field "next" (Decode.nullable slot))


{-| What's on at `now` (the server's clock): the next slot once the current
one's over, so titles change on time between polls.
-}
nowPlaying : Int -> OnAir -> NowPlaying
nowPlaying now { current, next } =
    case ( current.to, next ) of
        ( Just to, Just after ) ->
            if now >= to then
                after

            else
                current

        _ ->
            current


{-| Tell the phone what's on, for its lock screen and Control Centre.
-}
announce : NowPlaying -> Cmd msg
announce { artist, title, album } =
    radioOut
        (Encode.object
            [ ( "command", Encode.string "nowPlaying" )
            , ( "artist", Encode.string artist )
            , ( "title", Encode.string title )
            , ( "album", Encode.string (Maybe.withDefault "McTrot radio" album) )
            ]
        )


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


{-| The player: the title on now, and its artist (or how tuning in's
going, or what went wrong); while it plays, the album and year too, and how
far into the track it is. Without a program: "Radio", and whether it's on.
`now` is the server's clock, ms since the epoch.
-}
view : Maybe Int -> Maybe NowPlaying -> Model -> Html Msg
view now playing model =
    let
        on =
            model.state /= Stopped

        status =
            case ( model.state, playing ) of
                ( Connecting, _ ) ->
                    "Tuning in…"

                ( Failed message, _ ) ->
                    message

                ( _, Just { artist } ) ->
                    artist

                ( Stopped, Nothing ) ->
                    "Off"

                ( Playing, Nothing ) ->
                    "On"

        name =
            Maybe.map .title playing |> Maybe.withDefault "Radio"
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
            , Html.div
                [ Attr.class "radio-info"
                , Attr.attribute "aria-live" "polite"
                , case playing of
                    Just { artist, title } ->
                        Attr.title (title ++ " — " ++ artist)

                    Nothing ->
                        Attr.classList []
                ]
                ([ Html.span [ Attr.class "radio-name" ] [ Html.text name ]
                 , Html.span
                    [ Attr.class "radio-status"
                    , Attr.classList [ ( "radio-problem", isFailed model.state ), ( "radio-artist", playing /= Nothing && not (isFailed model.state) ) ]
                    ]
                    [ Html.text status ]
                 ]
                    ++ (case ( model.state, playing ) of
                            ( Playing, Just slot ) ->
                                viewDetails now slot

                            _ ->
                                []
                       )
                )
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


{-| While it plays: the album and its year, and the time into the track
against its length, with a bar.
-}
viewDetails : Maybe Int -> NowPlaying -> List (Html msg)
viewDetails now slot =
    let
        album =
            case ( slot.album, slot.year ) of
                ( Just name, Just year ) ->
                    Just (name ++ " · " ++ year)

                ( Just name, Nothing ) ->
                    Just name

                ( Nothing, Just year ) ->
                    Just year

                ( Nothing, Nothing ) ->
                    Nothing
    in
    (case album of
        Just text ->
            [ Html.span [ Attr.class "radio-album" ] [ Html.text text ] ]

        Nothing ->
            []
    )
        ++ (case ( now, slot.from, slot.to ) of
                ( Just t, Just from, Just to ) ->
                    let
                        length =
                            max 1 (to - from)

                        elapsed =
                            clamp 0 length (t - from)
                    in
                    [ Html.span [ Attr.class "radio-progress" ]
                        [ Html.span
                            [ Attr.class "radio-progress-bar"
                            , Attr.attribute "aria-hidden" "true"
                            ]
                            [ Html.span
                                [ Attr.class "radio-progress-fill"
                                , Attr.style "width" (String.fromFloat (toFloat elapsed / toFloat length * 100) ++ "%")
                                ]
                                []
                            ]
                        , Html.span [ Attr.class "radio-times" ]
                            [ Html.text (duration elapsed ++ " / " ++ duration length) ]
                        ]
                    ]

                _ ->
                    []
           )


{-| ms as "4:08" (or "1:02:03").
-}
duration : Int -> String
duration ms =
    let
        seconds =
            ms // 1000

        pad n =
            String.padLeft 2 '0' (String.fromInt n)
    in
    if seconds >= 3600 then
        String.fromInt (seconds // 3600) ++ ":" ++ pad (modBy 3600 seconds // 60) ++ ":" ++ pad (modBy 60 seconds)

    else
        String.fromInt (seconds // 60) ++ ":" ++ pad (modBy 60 seconds)


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
