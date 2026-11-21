module Icon exposing (Icon(..), view)

{-| /live's icons: IBM's Carbon icons (@carbon/icons 11.92.0, Apache-2.0;
the SVGs and the license are in website/icons/carbon/), drawn inline so
CSS can colour their parts (website/LIVE-DESIGN.md, "Icons").

The filled ones are two shapes: the disc (`.icon-disc`) with the symbol
cut out of it, and the symbol itself (`.icon-glyph`), which Carbon ships
as an invisible "inner path". Colouring the glyph turns a cut-out into a
two-tone icon: a yellow disc with a black ▶, say. Stop's square has no
inner path in Carbon, so it's added here. The outline ones are one shape
(`.icon-disc` too, so `fill` colours them).

Sizes come from CSS (width and height on `.icon`); the viewBox is
Carbon's 32 × 32.

-}

import Html exposing (Html)
import Html.Attributes
import Svg exposing (Svg)
import Svg.Attributes as A


type Icon
    = Play
    | Stop
    | Heart
    | HeartFilled
    | Link
    | Close
    | Plus
    | Minus
    | Maximize
    | Minimize
    | Previous
    | Next
    | Launch
    | Radio


view : Icon -> Html msg
view icon =
    let
        ( name, shapes ) =
            case icon of
                Play ->
                    ( "play"
                    , [ disc "M16,2A14,14,0,1,0,30,16,14,14,0,0,0,16,2Zm7.4473,14.8945-12,6A1,1,0,0,1,10,22V10a1,1,0,0,1,1.4473-.8945l12,6a1,1,0,0,1,0,1.789Z"
                      , glyph "M11,23a1,1,0,0,1-1-1V10a1,1,0,0,1,1.4473-.8945l12,6a1,1,0,0,1,0,1.789l-12,6A1.001,1.001,0,0,1,11,23Z"
                      ]
                    )

                Stop ->
                    ( "stop"
                    , [ disc "M16,2A14,14,0,1,0,30,16,14,14,0,0,0,16,2Zm6,18a2,2,0,0,1-2,2H12a2,2,0,0,1-2-2V12a2,2,0,0,1,2-2h8a2,2,0,0,1,2,2Z"
                      , glyph "M12,10h8a2,2,0,0,1,2,2v8a2,2,0,0,1-2,2H12a2,2,0,0,1-2-2V12a2,2,0,0,1,2-2Z"
                      ]
                    )

                Heart ->
                    ( "heart"
                    , [ disc "M22.45,6a5.47,5.47,0,0,1,3.91,1.64,5.7,5.7,0,0,1,0,8L16,26.13,5.64,15.64a5.7,5.7,0,0,1,0-8,5.48,5.48,0,0,1,7.82,0L16,10.24l2.53-2.58A5.44,5.44,0,0,1,22.45,6m0-2a7.47,7.47,0,0,0-5.34,2.24L16,7.36,14.89,6.24a7.49,7.49,0,0,0-10.68,0,7.72,7.72,0,0,0,0,10.82L16,29,27.79,17.06a7.72,7.72,0,0,0,0-10.82A7.49,7.49,0,0,0,22.45,4Z" ]
                    )

                HeartFilled ->
                    ( "heart-filled"
                    , [ disc "M22.5,4c-2,0-3.9,0.8-5.3,2.2L16,7.4l-1.1-1.1C12,3.3,7.2,3.3,4.3,6.2c0,0-0.1,0.1-0.1,0.1c-3,3-3,7.8,0,10.8L16,29l11.8-11.9c3-3,3-7.8,0-10.8C26.4,4.8,24.5,4,22.5,4z" ]
                    )

                Link ->
                    ( "link"
                    , [ disc "M29.25,6.76a6,6,0,0,0-8.5,0l1.42,1.42a4,4,0,1,1,5.67,5.67l-8,8a4,4,0,1,1-5.67-5.66l1.41-1.42-1.41-1.42-1.42,1.42a6,6,0,0,0,0,8.5A6,6,0,0,0,17,25a6,6,0,0,0,4.27-1.76l8-8A6,6,0,0,0,29.25,6.76Z"
                      , disc "M4.19,24.82a4,4,0,0,1,0-5.67l8-8a4,4,0,0,1,5.67,0A3.94,3.94,0,0,1,19,14a4,4,0,0,1-1.17,2.85L15.71,19l1.42,1.42,2.12-2.12a6,6,0,0,0-8.51-8.51l-8,8a6,6,0,0,0,0,8.51A6,6,0,0,0,7,28a6.07,6.07,0,0,0,4.28-1.76L9.86,24.82A4,4,0,0,1,4.19,24.82Z"
                      ]
                    )

                Close ->
                    ( "close"
                    , [ disc "M16,2C8.2,2,2,8.2,2,16s6.2,14,14,14s14-6.2,14-14S23.8,2,16,2z M21.4,23L16,17.6L10.6,23L9,21.4l5.4-5.4L9,10.6L10.6,9l5.4,5.4L21.4,9l1.6,1.6L17.6,16l5.4,5.4L21.4,23z"
                      , glyph "M14.4 16 9 10.6 10.6 9 16 14.4 21.4 9 23 10.6 17.6 16 23 21.4 21.4 23 16 17.6 10.6 23 9 21.4 14.4 16"
                      ]
                    )

                Plus ->
                    ( "plus"
                    , [ disc "M16,2A14.1725,14.1725,0,0,0,2,16,14.1725,14.1725,0,0,0,16,30,14.1725,14.1725,0,0,0,30,16,14.1725,14.1725,0,0,0,16,2Zm8,15H17v7H15V17H8V15h7V8h2v7h7Z"
                      , glyph "M24 17 17 17 17 24 15 24 15 17 8 17 8 15 15 15 15 8 17 8 17 15 24 15 24 17z"
                      ]
                    )

                Minus ->
                    ( "minus"
                    , [ disc "m16,2c-7.6,0-14,6.4-14,14s6.4,14,14,14,14-6.4,14-14S23.6,2,16,2Zm8,15H8v-2h16v2Z"
                      , glyph "M24 17 8 17 8 15 24 15 24 17z"
                      ]
                    )

                Maximize ->
                    ( "maximize"
                    , [ disc "M20 2 20 4 26.586 4 18 12.582 19.414 14 28 5.414 28 12 30 12 30 2 20 2z"
                      , disc "M14 19.416 12.592 18 4 26.586 4 20 2 20 2 30 12 30 12 28 5.414 28 14 19.416z"
                      ]
                    )

                Minimize ->
                    ( "minimize"
                    , [ disc "M4 18 4 20 10.586 20 2 28.582 3.414 30 12 21.414 12 28 14 28 14 18 4 18z"
                      , disc "M30 3.416 28.592 2 20 10.586 20 4 18 4 18 14 28 14 28 12 21.414 12 30 3.416z"
                      ]
                    )

                Previous ->
                    ( "previous"
                    , [ disc "M16,2A14,14,0,1,0,30,16,14,14,0,0,0,16,2Zm8,15H11.85l5.58,5.5728L16,24,8,16l8-8,1.43,1.3926L11.85,15H24Z"
                      , glyph "M16 8 17.43 9.393 11.85 15 24 15 24 17 11.85 17 17.43 22.573 16 24 8 16 16 8z"
                      ]
                    )

                Next ->
                    ( "next"
                    , [ disc "M2,16A14,14,0,1,0,16,2,14,14,0,0,0,2,16Zm6-1H20.15L14.57,9.3926,16,8l8,8-8,8-1.43-1.4272L20.15,17H8Z"
                      , glyph "M16 8 14.57 9.393 20.15 15 8 15 8 17 20.15 17 14.57 22.573 16 24 24 16 16 8z"
                      ]
                    )

                Launch ->
                    ( "launch"
                    , [ disc "M26,28H6a2.0027,2.0027,0,0,1-2-2V6A2.0027,2.0027,0,0,1,6,4H16V6H6V26H26V16h2V26A2.0027,2.0027,0,0,1,26,28Z"
                      , disc "M20 2 20 4 26.586 4 18 12.586 19.414 14 28 5.414 28 12 30 12 30 2 20 2z"
                      ]
                    )

                Radio ->
                    ( "radio"
                    , [ disc "M28,10H24V2H22v8H13V8H11v2H8V8H6v2H4a2,2,0,0,0-2,2V28a2,2,0,0,0,2,2H28a2,2,0,0,0,2-2V12A2,2,0,0,0,28,10ZM4,28V12H28V28Z"
                      , disc "M10 26a4 4 0 114-4A4 4 0 0110 26zm0-6a2 2 0 102 2A2 2 0 0010 20zM7 14H13V16H7zM17 16H26V18H17zM17 20H26V22H17zM17 24H26V26H17z"
                      ]
                    )
    in
    Svg.svg
        [ A.viewBox "0 0 32 32"
        , A.class ("icon icon-" ++ name)
        , Html.Attributes.attribute "focusable" "false"
        , Html.Attributes.attribute "aria-hidden" "true"
        ]
        shapes


disc : String -> Svg msg
disc d =
    Svg.path [ A.class "icon-disc", A.d d ] []


glyph : String -> Svg msg
glyph d =
    Svg.path [ A.class "icon-glyph", A.d d ] []
