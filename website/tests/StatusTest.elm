module StatusTest exposing (suite)

import Expect
import Status exposing (PostKind(..))
import Test exposing (Test, describe, test)


{-| The walk's planned start: November 21, 2026, 5:05 AM EST.
-}
start : Int
start =
    1795255500000


minute : Int
minute =
    60000


hour : Int
hour =
    60 * minute


{-| The sun on November 21, as offsets from the start (5:05 AM).
-}
sun =
    { astronomicalDawn = Just (start + 8 * minute)
    , nauticalDawn = Just (start + 41 * minute)
    , civilDawn = Just (start + 74 * minute)
    , sunrise = Just (start + 104 * minute)
    , solarNoon = start + 6 * hour + 47 * minute
    , sunset = Just (start + 11 * hour + 26 * minute)
    , civilDusk = Just (start + 11 * hour + 56 * minute)
    , nauticalDusk = Just (start + 12 * hour + 29 * minute)
    , astronomicalDusk = Just (start + 13 * hour + 1 * minute)
    }


opener : String
opener =
    "Zach Rose’s annual challenge to eat at every McDonald’s in Manhattan, on foot, in one go. The goal for this year is 10 hours."


before : Int -> Status.Input {}
before now =
    { now = now
    , stores = 46
    , start = Just { at = start, address = "608 West 207th Street" }
    , visits = []
    , weather = Nothing
    , sun = Nothing
    , latestPost = Nothing
    , radio = Nothing
    }


{-| `n` McDonald's visited, each `late` minutes after its planned arrival
(planned every 12 minutes from the start).
-}
visits : Int -> Int -> List { planned : Maybe Int, at : Int }
visits n late =
    List.range 0 (n - 1) |> List.map (\i -> { planned = Just (start + i * 12 * minute), at = start + (i * 12 + late) * minute })


plainWeather : Status.Weather
plainWeather =
    { summary = Just "Overcast", temperatureF = Just 47.2, feelsLikeF = Just 44, windMph = Just 4, gustMph = Just 8, windFrom = Just "SW" }


suite : Test
suite =
    describe "Status"
        [ describe "before the start"
            [ test "more than a day out, the date" <|
                \_ ->
                    Status.paragraph (before (start - 2 * 24 * hour))
                        |> Expect.equal (opener ++ " The route will cover 26.7 miles. Beginning Saturday, November 21 at 5:05 AM at 608 West 207th Street.")
            , test "under a day, a countdown" <|
                \_ ->
                    Status.paragraph (before (start - 7 * hour - 52 * minute))
                        |> Expect.equal (opener ++ " The route will cover 26.7 miles. Beginning in 7 hours 52 minutes at 608 West 207th Street.")
            , test "under an hour" <|
                \_ ->
                    Status.paragraph (before (start - 14 * minute + 20000))
                        |> Expect.equal (opener ++ " The route will cover 26.7 miles. Beginning in 14 minutes at 608 West 207th Street.")
            , test "on the hour" <|
                \_ ->
                    Status.paragraph (before (start - 3 * hour))
                        |> Expect.equal (opener ++ " The route will cover 26.7 miles. Beginning in 3 hours at 608 West 207th Street.")
            , test "due, with no visit yet" <|
                \_ ->
                    Status.paragraph (before (start + 3 * minute))
                        |> Expect.equal (opener ++ " The route will cover 26.7 miles. Beginning any minute now at 608 West 207th Street.")
            ]
        , describe "during"
            [ test "behind plan, with weather, a post and the radio" <|
                \_ ->
                    let
                        now =
                            start + 4 * hour + 12 * minute + 30000
                    in
                    Status.paragraph
                        { now = now
                        , stores = 46
                        , start = Nothing
                        , visits = { planned = Just start, at = start } :: List.drop 1 (visits 22 9)
                        , weather = Just plainWeather
                        , sun = Just sun
                        , latestPost = Just { at = now - 3 * minute, kind = TextPost "Wind tunnel on 6th. Hat gone." }
                        , radio = Just { title = "Mr. Blue Sky", artist = "Electric Light Orchestra" }
                        }
                        |> Expect.equal (opener ++ " 22 of 46 visited, 24 to go, 4 hours 12 minutes in and 9 minutes behind plan. Overcast, 47°F. “Wind tunnel on 6th. Hat gone.” posted 3 minutes ago. On McTrot Radio: Mr. Blue Sky by Electric Light Orchestra.")
            , test "ahead of plan, in the dark" <|
                \_ ->
                    Status.paragraph
                        { now = start + 3 * minute
                        , stores = 46
                        , start = Nothing
                        , visits = [ { planned = Just (start + 2 * minute), at = start } ]
                        , weather = Nothing
                        , sun = Just sun
                        , latestPost = Nothing
                        , radio = Nothing
                        }
                        |> Expect.equal (opener ++ " 1 of 46 visited, 45 to go, 3 minutes in and 2 minutes ahead of plan. Dark, 5 minutes until astronomical twilight.")
            , test "on plan" <|
                \_ ->
                    Status.paragraph
                        { now = start + 30 * minute
                        , stores = 46
                        , start = Nothing
                        , visits = visits 3 0
                        , weather = Nothing
                        , sun = Nothing
                        , latestPost = Nothing
                        , radio = Nothing
                        }
                        |> Expect.equal (opener ++ " 3 of 46 visited, 43 to go, 30 minutes in and on plan.")
            ]
        , describe "finished"
            [ test "all of them, with the time taken" <|
                \_ ->
                    Status.paragraph
                        { now = start + 9 * hour + 42 * minute
                        , stores = 2
                        , start = Nothing
                        , visits = [ { planned = Nothing, at = start }, { planned = Nothing, at = start + 9 * hour + 38 * minute } ]
                        , weather = Just { plainWeather | summary = Just "Clear", temperatureF = Just 44, feelsLikeF = Just 41 }
                        , sun = Nothing
                        , latestPost = Nothing
                        , radio = Nothing
                        }
                        |> Expect.equal "Zach Rose’s annual challenge to eat at every McDonald’s in Manhattan, on foot, in one go. The goal for this year was 10 hours. Done: all 2 in 9 hours 38 minutes. Clear, 44°F."
            ]
        , describe "the light"
            [ lightAt 0 (Just "Dark, 8 minutes until astronomical twilight.")
            , lightAt 20 (Just "Astronomical twilight, 21 minutes until nautical twilight.")
            , lightAt 50 (Just "Nautical twilight, 24 minutes until civil twilight.")
            , lightAt 92 (Just "Civil twilight, 12 minutes until sunrise.")
            , lightAt 110 (Just "Sunrise 6 minutes ago.")
            , lightAt 125 Nothing
            , lightAt (6 * 60 + 41) (Just "Solar noon in 6 minutes.")
            , lightAt (6 * 60 + 51) (Just "Solar noon 4 minutes ago.")
            , lightAt (6 * 60 + 47) (Just "Solar noon now.")
            , lightAt (8 * 60) Nothing
            , lightAt (11 * 60 + 17) (Just "Sunset in 9 minutes.")
            , lightAt (11 * 60 + 36) (Just "Civil twilight, 20 minutes until nautical twilight.")
            , lightAt (12 * 60 + 10) (Just "Nautical twilight, 19 minutes until astronomical twilight.")
            , lightAt (12 * 60 + 40) (Just "Astronomical twilight, 21 minutes until dark.")
            , lightAt (14 * 60) (Just "Dark.")
            ]
        , describe "the weather"
            [ test "sky and temperature" <|
                \_ -> Status.weather plainWeather |> Expect.equal "Overcast, 47°F."
            , test "feels-like 5°F or more off" <|
                \_ -> Status.weather { plainWeather | summary = Just "Clear", temperatureF = Just 38, feelsLikeF = Just 31 } |> Expect.equal "Clear, 38°F, feels like 31°F."
            , test "wind at 10 mph or more, with gusts" <|
                \_ ->
                    Status.weather { plainWeather | summary = Just "Light rain", temperatureF = Just 44, feelsLikeF = Just 41, windMph = Just 14, gustMph = Just 22, windFrom = Just "NW" }
                        |> Expect.equal "Light rain, 44°F, wind NW 14 mph, gusts 22."
            ]
        , describe "the latest post"
            [ postSays (TextPost "Coffee was a mistake.") 6 (Just "“Coffee was a mistake.” posted 6 minutes ago.")
            , postSays PhotoPost 14 (Just "A photo posted 14 minutes ago.")
            , postSays VoicePost 0 (Just "A voice note posted just now.")
            , postSays VideoPost 1 (Just "A video posted 1 minute ago.")
            , postSays PhotoPost 61 Nothing
            , postSays (TextPost "Stopped for a minute. My feet are fine. My feet are not fine. This is a deliberately long post.") 5
                (Just "“Stopped for a minute. My feet are fine. My feet are not fine. This is a…” posted 5 minutes ago.")
            ]
        ]


lightAt : Int -> Maybe String -> Test
lightAt minutesFromStart expected =
    test ("light at start + " ++ String.fromInt minutesFromStart ++ " min") <|
        \_ -> Status.light (start + minutesFromStart * minute) sun |> Expect.equal expected


{-| What the paragraph says about a post `ago` minutes old, as its last
sentence (or nothing).
-}
postSays : PostKind -> Int -> Maybe String -> Test
postSays kind ago expected =
    test ("a post " ++ String.fromInt ago ++ " minutes old") <|
        \_ ->
            let
                now =
                    start + hour

                text =
                    Status.paragraph
                        { now = now
                        , stores = 46
                        , start = Nothing
                        , visits = [ { planned = Nothing, at = start } ]
                        , weather = Nothing
                        , sun = Nothing
                        , latestPost = Just { at = now - ago * minute, kind = kind }
                        , radio = Nothing
                        }

                withoutPost =
                    opener ++ " 1 of 46 visited, 45 to go, 1 hour in."
            in
            (if text == withoutPost then
                Nothing

             else
                Just (String.dropLeft (String.length withoutPost + 1) text)
            )
                |> Expect.equal expected
