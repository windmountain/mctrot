module Status exposing (Input, PostKind(..), Weather, light, paragraph, weather)

{-| The overview's paragraph (/live): what McTrot is, then where the walk
stands, in plain sentences that read a little like a machine wrote them.
See website/LIVE-DESIGN.md, "The paragraph".

Before the start:

    Zach Rose’s annual challenge to eat at every McDonald’s in Manhattan,
    on foot, in one go. The goal for this year is 10 hours. The route will
    cover 26.7 miles. Beginning in 7 hours 52 minutes at 608 West 207th
    Street.

During:

    …The goal for this year is 10 hours. 22 of 46 visited, 24 to go,
    4 hours 12 minutes in and 9 minutes behind plan. Overcast, 47°F.
    “Wind tunnel on 6th. Hat gone.” posted 3 minutes ago. On McTrot
    Radio: Mr. Blue Sky by Electric Light Orchestra.

Finished:

    …The goal for this year was 10 hours. Done: all 46 in 9 hours 38
    minutes. Clear, 44°F.

Pure: everything it needs comes in an Input, so it's tested on its own
(tests/StatusTest.elm). No store nicknames anywhere.

-}

import NewYorkTime
import SolarTime


{-| `visits`: one per McDonald's visited, its planned arrival (if the plan
has times) and its first check-in. `stores`: how many there are. `start`:
the plan's first arrival, and its address.
-}
type alias Input sun =
    { now : Int
    , stores : Int
    , start : Maybe { at : Int, address : String }
    , visits : List { planned : Maybe Int, at : Int }
    , weather : Maybe Weather
    , sun : Maybe (SolarTime.Times sun)
    , latestPost : Maybe { at : Int, kind : PostKind }
    , radio : Maybe { title : String, artist : String }
    }


type alias Weather =
    { summary : Maybe String
    , temperatureF : Maybe Float
    , feelsLikeF : Maybe Float
    , windMph : Maybe Float
    , gustMph : Maybe Float
    , windFrom : Maybe String
    }


type PostKind
    = TextPost String
    | PhotoPost
    | VideoPost
    | VoicePost


{-| The planned route's length, from the simulator.
-}
routeMiles : String
routeMiles =
    "26.7"


goalHours : Int
goalHours =
    10


minuteMs : Int
minuteMs =
    60000


paragraph : Input sun -> String
paragraph input =
    let
        visited =
            List.length input.visits

        finished =
            input.stores > 0 && visited >= input.stores

        opener =
            "Zach Rose’s annual challenge to eat at every McDonald’s in Manhattan, on foot, in one go. The goal for this year "
                ++ (if finished then
                        "was "

                    else
                        "is "
                   )
                ++ String.fromInt goalHours
                ++ " hours."

        conditions =
            [ Maybe.andThen (light input.now) input.sun
            , Maybe.map weather input.weather
            , Maybe.andThen (latestPost input.now) input.latestPost
            , Maybe.map (\{ title, artist } -> "On McTrot Radio: " ++ title ++ " by " ++ artist ++ ".") input.radio
            ]
                |> List.filterMap identity
    in
    if visited == 0 then
        String.join " "
            (opener
                :: ("The route will cover " ++ routeMiles ++ " miles.")
                :: (case input.start of
                        Just start ->
                            [ "Beginning " ++ countdown input.now start.at ++ " at " ++ start.address ++ "." ]

                        Nothing ->
                            []
                   )
            )

    else
        let
            first =
                List.map .at input.visits |> List.minimum |> Maybe.withDefault input.now

            last =
                input.visits |> List.sortBy .at |> List.reverse |> List.head

            progress =
                if finished then
                    "Done: all " ++ String.fromInt input.stores ++ " in " ++ span (Maybe.map .at last |> Maybe.withDefault input.now) first ++ "."

                else
                    String.fromInt visited
                        ++ " of "
                        ++ String.fromInt input.stores
                        ++ " visited, "
                        ++ String.fromInt (input.stores - visited)
                        ++ " to go, "
                        ++ span input.now first
                        ++ " in"
                        ++ (case last |> Maybe.andThen (\v -> Maybe.map (\planned -> planned - v.at) v.planned) of
                                Just ahead ->
                                    " and " ++ pace ahead ++ "."

                                Nothing ->
                                    "."
                           )
        in
        String.join " " (opener :: progress :: conditions)


{-| How far away the start is: a date more than a day out, then a
countdown, then "any minute now" once it's due.
-}
countdown : Int -> Int -> String
countdown now start =
    let
        minutes =
            ceiling (toFloat (start - now) / toFloat minuteMs)
    in
    if minutes <= 0 then
        "any minute now"

    else if minutes > 24 * 60 then
        NewYorkTime.weekday start
            ++ ", "
            ++ (NewYorkTime.format start |> String.split "," |> List.head |> Maybe.withDefault "")
            ++ " at "
            ++ NewYorkTime.clock start

    else
        "in " ++ hoursMinutes minutes


{-| "9 minutes behind plan", "1 hour 2 minutes ahead of plan", "on plan":
`ahead` is planned arrival minus actual, in ms, at the latest McDonald's.
-}
pace : Int -> String
pace ahead =
    let
        minutes =
            round (toFloat ahead / toFloat minuteMs)
    in
    if minutes > 0 then
        hoursMinutes minutes ++ " ahead of plan"

    else if minutes < 0 then
        hoursMinutes -minutes ++ " behind plan"

    else
        "on plan"


{-| The time between two moments, to the minute: "4 hours 12 minutes".
-}
span : Int -> Int -> String
span to from =
    hoursMinutes (max 0 ((to - from) // minuteMs))


hoursMinutes : Int -> String
hoursMinutes minutes =
    let
        h =
            minutes // 60

        m =
            modBy 60 minutes
    in
    if h == 0 then
        plural m "minute"

    else if m == 0 then
        plural h "hour"

    else
        plural h "hour" ++ " " ++ plural m "minute"


plural : Int -> String -> String
plural n unit =
    String.fromInt n
        ++ " "
        ++ unit
        ++ (if n == 1 then
                ""

            else
                "s"
           )


{-| The light, only when it isn't plain daylight: the darkness or twilight
and the minutes until the next, or, within 15 minutes of sunrise, solar
noon or sunset, how far off that is. Nothing in plain daylight.
-}
light : Int -> SolarTime.Times sun -> Maybe String
light now sun =
    let
        window =
            15

        -- Whole minutes from now until `t` (negative once past).
        until t =
            round (toFloat (t - now) / toFloat minuteMs)

        before t =
            Maybe.map (\ms -> now < ms) t |> Maybe.withDefault False

        nextIn phase t next =
            Maybe.map (\ms -> phase ++ ", " ++ hoursMinutes (max 1 (until ms)) ++ " until " ++ next ++ ".") t

        near event t =
            let
                m =
                    until t
            in
            if m > 0 then
                Just (event ++ " in " ++ plural m "minute" ++ ".")

            else if m < 0 then
                Just (event ++ " " ++ plural -m "minute" ++ " ago.")

            else
                Just (event ++ " now.")

        within t =
            abs (until t) <= window
    in
    if before sun.astronomicalDawn then
        nextIn "Dark" sun.astronomicalDawn "astronomical twilight"

    else if before sun.nauticalDawn then
        nextIn "Astronomical twilight" sun.nauticalDawn "nautical twilight"

    else if before sun.civilDawn then
        nextIn "Nautical twilight" sun.civilDawn "civil twilight"

    else if before sun.sunrise then
        nextIn "Civil twilight" sun.sunrise "sunrise"

    else if Maybe.map (\t -> until t > -window) sun.sunrise |> Maybe.withDefault False then
        Maybe.andThen (near "Sunrise") sun.sunrise

    else if within sun.solarNoon then
        near "Solar noon" sun.solarNoon

    else if Maybe.map (\t -> now < t && until t <= window) sun.sunset |> Maybe.withDefault False then
        Maybe.andThen (near "Sunset") sun.sunset

    else if before sun.sunset then
        Nothing

    else if before sun.civilDusk then
        nextIn "Civil twilight" sun.civilDusk "nautical twilight"

    else if before sun.nauticalDusk then
        nextIn "Nautical twilight" sun.nauticalDusk "astronomical twilight"

    else if before sun.astronomicalDusk then
        nextIn "Astronomical twilight" sun.astronomicalDusk "dark"

    else
        Just "Dark."


{-| "Overcast, 47°F." Feels-like only 5°F or more off; wind only at 10 mph
or more, with gusts if reported: "Light rain, 44°F, wind NW 14 mph, gusts
22."
-}
weather : Weather -> String
weather w =
    let
        degrees f =
            String.fromInt (round f) ++ "°F"

        feels =
            case ( w.temperatureF, w.feelsLikeF ) of
                ( Just t, Just f ) ->
                    if abs (f - t) >= 5 then
                        Just ("feels like " ++ degrees f)

                    else
                        Nothing

                _ ->
                    Nothing

        wind =
            w.windMph
                |> Maybe.andThen
                    (\speed ->
                        if speed >= 10 then
                            Just
                                ("wind "
                                    ++ (w.windFrom |> Maybe.map (\d -> d ++ " ") |> Maybe.withDefault "")
                                    ++ String.fromInt (round speed)
                                    ++ " mph"
                                    ++ (w.gustMph |> Maybe.map (\g -> ", gusts " ++ String.fromInt (round g)) |> Maybe.withDefault "")
                                )

                        else
                            Nothing
                    )

        parts =
            [ w.summary, Maybe.map degrees w.temperatureF, feels, wind ] |> List.filterMap identity
    in
    if List.isEmpty parts then
        ""

    else
        capitalize (String.join ", " parts) ++ "."


capitalize : String -> String
capitalize text =
    String.toUpper (String.left 1 text) ++ String.dropLeft 1 text


{-| The newest post, if it's under an hour old: a text post quoted (cut
near 80 characters), anything else by its kind.
-}
latestPost : Int -> { at : Int, kind : PostKind } -> Maybe String
latestPost now post =
    let
        minutes =
            (now - post.at) // minuteMs

        ago =
            if minutes < 1 then
                "posted just now."

            else
                "posted " ++ plural minutes "minute" ++ " ago."
    in
    if minutes >= 60 then
        Nothing

    else
        Just
            ((case post.kind of
                TextPost text ->
                    "“" ++ cut 80 (String.trim text) ++ "”"

                PhotoPost ->
                    "A photo"

                VideoPost ->
                    "A video"

                VoicePost ->
                    "A voice note"
             )
                ++ " "
                ++ ago
            )


{-| At most `n` characters, cut at a word with "…".
-}
cut : Int -> String -> String
cut n text =
    if String.length text <= n then
        text

    else
        let
            words =
                String.words (String.left n text)

            kept =
                if List.length words > 1 then
                    List.take (List.length words - 1) words

                else
                    words
        in
        String.join " " kept ++ "…"
