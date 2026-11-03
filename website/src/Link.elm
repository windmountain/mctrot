module Link exposing (Settings, formatTime, fromQuery, toQuery)

{-| The simulator's settings as URL query parameters, so a link reproduces
a search exactly (the search is deterministic given its settings; see
Simulator's `startSearch`):

    ?date=2026-11-21&start=05:00&pace=20&stop=5&seed=1&from=40&to=106

`from` and `to` are location ids from website/data/mcd_locations.csv
(`MctrotMapData.mcdIds`), not city indices, so a link keeps naming the same
locations if one is added or removed; `any` means flexible.

-}

import Array
import Calendar
import MctrotMapData
import Url


{-| One search's settings. `minutes` is the start time in minutes since
midnight; `from`/`to` are city indices (`Nothing` = flexible).
-}
type alias Settings =
    { date : String
    , minutes : Int
    , pace : Float
    , stop : Int
    , seed : Int
    , from : Maybe Int
    , to : Maybe Int
    }


{-| Every parameter, always, so a link doesn't change meaning if a default
does. Starts with "?".
-}
toQuery : Settings -> String
toQuery s =
    "?"
        ++ String.join "&"
            [ "date=" ++ Url.percentEncode s.date
            , "start=" ++ formatTime s.minutes
            , "pace=" ++ String.fromFloat s.pace
            , "stop=" ++ String.fromInt s.stop
            , "seed=" ++ String.fromInt s.seed
            , "from=" ++ cityParam s.from
            , "to=" ++ cityParam s.to
            ]


{-| Reads the decoded query pairs over `defaults`: each missing or invalid
parameter keeps its default. `Nothing` if none of the parameters is present
(an ordinary visit, not a link).
-}
fromQuery : Settings -> List ( String, String ) -> Maybe Settings
fromQuery defaults pairs =
    let
        get key =
            List.filter (\( k, _ ) -> k == key) pairs |> List.head |> Maybe.map Tuple.second

        read key parse fallback =
            get key |> Maybe.andThen parse |> Maybe.withDefault fallback
    in
    if List.any (\( k, _ ) -> List.member k keys) pairs then
        Just
            { date = read "date" parseDate defaults.date
            , minutes = read "start" parseTime defaults.minutes
            , pace = read "pace" parsePace defaults.pace
            , stop = read "stop" parseStop defaults.stop
            , seed = read "seed" String.toInt defaults.seed
            , from = read "from" parseCity defaults.from
            , to = read "to" parseCity defaults.to
            }

    else
        Nothing


{-| Minutes since midnight as "HH:MM", the format `<input type="time">`
takes.
-}
formatTime : Int -> String
formatTime minutes =
    pad2 (minutes // 60) ++ ":" ++ pad2 (modBy 60 minutes)


keys : List String
keys =
    [ "date", "start", "pace", "stop", "seed", "from", "to" ]


parseDate : String -> Maybe String
parseDate raw =
    -- Calendar.parseDate takes Feb 30; a real date survives the round trip.
    Calendar.parseDate raw
        |> Maybe.andThen
            (\date ->
                if Calendar.addDays 0 date == date then
                    Just (Calendar.formatIso date)

                else
                    Nothing
            )


parseTime : String -> Maybe Int
parseTime raw =
    case String.split ":" raw |> List.map String.toInt of
        [ Just hh, Just mm ] ->
            if hh >= 0 && hh < 24 && mm >= 0 && mm < 60 then
                Just (hh * 60 + mm)

            else
                Nothing

        _ ->
            Nothing


parsePace : String -> Maybe Float
parsePace raw =
    String.toFloat raw
        |> Maybe.andThen
            (\pace ->
                if pace > 0 then
                    Just pace

                else
                    Nothing
            )


parseStop : String -> Maybe Int
parseStop raw =
    String.toInt raw
        |> Maybe.andThen
            (\stop ->
                if stop >= 0 then
                    Just stop

                else
                    Nothing
            )


{-| `Just Nothing` for "any", `Just (Just index)` for a known location id.
-}
parseCity : String -> Maybe (Maybe Int)
parseCity raw =
    if raw == "any" then
        Just Nothing

    else
        String.toInt raw
            |> Maybe.andThen
                (\id ->
                    MctrotMapData.mcdIds
                        |> Array.toIndexedList
                        |> List.filter (\( _, mcdId ) -> mcdId == id)
                        |> List.head
                        |> Maybe.map (Tuple.first >> Just)
                )


cityParam : Maybe Int -> String
cityParam city =
    city
        |> Maybe.andThen (\i -> Array.get i MctrotMapData.mcdIds)
        |> Maybe.map String.fromInt
        |> Maybe.withDefault "any"


pad2 : Int -> String
pad2 n =
    String.padLeft 2 '0' (String.fromInt n)
