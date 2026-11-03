module Gpx exposing (Route, Stop, build, legKey)

{-| The simulator's route as a GPX 1.1 file: a waypoint at every stop, in
visiting order, and one track along the walking legs between them (from
geo/route-legs.json; see `legKey`).
-}

import Calendar
import Dict exposing (Dict)
import Polyline


{-| `arrival` is minutes after midnight beginning the route's start date (so
past 1440 on later days), the same clock as `Simulator.Visit`. `desc` is
free text for the waypoint.
-}
type alias Stop =
    { mcdId : Int
    , name : String
    , desc : String
    , lat : Float
    , lon : Float
    , arrival : Int
    }


{-| `date` is `Nothing` if the start date is invalid, which leaves out every
`<time>`. `legs` maps `legKey`s to encoded polylines.
-}
type alias Route =
    { name : String
    , date : Maybe Calendar.Date
    , legs : Dict String String
    , stops : List Stop
    }


{-| A leg's key in geo/route-legs.json: the two real `mcd_id`s, lower
first ("3-17"). Its polyline runs from the lower to the higher.
-}
legKey : Int -> Int -> String
legKey a b =
    String.fromInt (min a b) ++ "-" ++ String.fromInt (max a b)


build : Route -> String
build route =
    String.join "\n"
        (List.concat
            [ [ "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
              , "<gpx version=\"1.1\" creator=\"McTrot Simulator\" xmlns=\"http://www.topografix.com/GPX/1/1\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd\">"
              , "<metadata>"
              , element "name" route.name
              , "<link href=\"https://mctrot.nyc/simulator.html\">" ++ element "text" "McTrot Simulator" ++ "</link>"
              ]
            , List.head route.stops |> Maybe.map (timeElement route.date) |> Maybe.withDefault []
            , [ "</metadata>" ]
            , List.map (waypoint route.date) route.stops
            , [ "<trk>"
              , element "name" route.name
              , "<trkseg>"
              ]
            , List.map trackPoint (track route.legs route.stops)
            , [ "</trkseg>", "</trk>", "</gpx>", "" ]
            ]
        )


waypoint : Maybe Calendar.Date -> Stop -> String
waypoint date stop =
    String.concat
        (("<wpt lat=\"" ++ fixed 6 stop.lat ++ "\" lon=\"" ++ fixed 6 stop.lon ++ "\">")
            :: timeElement date stop
            ++ [ element "name" stop.name, element "desc" stop.desc, "</wpt>" ]
        )


timeElement : Maybe Calendar.Date -> Stop -> List String
timeElement date stop =
    case date of
        Just d ->
            [ element "time" (Calendar.isoUtcFromNewYork d stop.arrival) ]

        Nothing ->
            []


trackPoint : ( Float, Float ) -> String
trackPoint ( lat, lon ) =
    "<trkpt lat=\"" ++ fixed 5 lat ++ "\" lon=\"" ++ fixed 5 lon ++ "\"/>"


{-| Every leg's points end to end, each leg turned around when it's walked
from the higher `mcd_id` to the lower. Consecutive legs meet at the same
point, which is kept once. A leg missing from `legs` (or a stop repeated
back to back) adds nothing.
-}
track : Dict String String -> List Stop -> List ( Float, Float )
track legs stops =
    let
        legPoints from to =
            case Dict.get (legKey from.mcdId to.mcdId) legs of
                Just encoded ->
                    if from.mcdId < to.mcdId then
                        Polyline.decode encoded

                    else
                        List.reverse (Polyline.decode encoded)

                Nothing ->
                    []

        append points acc =
            case ( acc, points ) of
                ( last :: _, first :: rest ) ->
                    if last == first then
                        List.foldl (::) acc rest

                    else
                        List.foldl (::) acc points

                _ ->
                    List.foldl (::) acc points
    in
    List.map2 legPoints stops (List.drop 1 stops)
        |> List.foldl append []
        |> List.reverse


element : String -> String -> String
element name text =
    "<" ++ name ++ ">" ++ escape text ++ "</" ++ name ++ ">"


escape : String -> String
escape =
    String.replace "&" "&amp;"
        >> String.replace "<" "&lt;"
        >> String.replace ">" "&gt;"
        >> String.replace "\"" "&quot;"
        >> String.replace "'" "&apos;"


{-| A coordinate to exactly `decimals` places, without float noise:
`fixed 5 -73.9413` is "-73.94130".
-}
fixed : Int -> Float -> String
fixed decimals x =
    let
        scale =
            10 ^ decimals

        n =
            round (abs x * toFloat scale)

        sign =
            if x < 0 && n /= 0 then
                "-"

            else
                ""
    in
    sign ++ String.fromInt (n // scale) ++ "." ++ String.padLeft decimals '0' (String.fromInt (modBy scale n))
