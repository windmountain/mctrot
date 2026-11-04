port module MegaSearchWorker exposing (main)

{-| Runs one mega search job at a time to completion, inside a Web Worker
(see js/mega-search-worker.js), so the page stays responsive while several
of these run in parallel.

A job is one cell of the landscape: a start date and time, a start location,
and the shared pace and stop length, with the finish left flexible. It's
searched with `Search.start` and `Search.finish`, exactly as the simulator
searches the same settings, so the simulator link for a cell (see
`MegaSearch.simulatorLink`) finds the same route.

-}

import Json.Decode as Decode
import Json.Encode as Encode
import List.Extra
import Search
import SimulatedAnnealing


port job : (Decode.Value -> msg) -> Sub msg


port done : Encode.Value -> Cmd msg


type alias Job =
    { id : String
    , weekday : Int
    , minutes : Int
    , pace : Float
    , stop : Int
    , startCity : Int
    , seed : Int
    }


jobDecoder : Decode.Decoder Job
jobDecoder =
    Decode.map7 Job
        (Decode.field "id" Decode.string)
        (Decode.field "weekday" Decode.int)
        (Decode.field "minutes" Decode.int)
        (Decode.field "pace" Decode.float)
        (Decode.field "stop" Decode.int)
        (Decode.field "startCity" Decode.int)
        (Decode.field "seed" Decode.int)


{-| `finish` is the city index the best route ends at; `minutes` and `meters`
are its total time (waits included) and walking distance.
-}
run : Job -> Encode.Value
run j =
    let
        startTime =
            { weekday = j.weekday
            , date = Nothing
            , minutes = j.minutes
            , metersPerMinute = Search.metersPerMinuteFromPace j.pace
            , stopMinutes = j.stop
            , startCity = Just j.startCity
            , endCity = Nothing
            }

        tour =
            Search.start startTime j.seed
                |> Search.finish startTime
                |> SimulatedAnnealing.best
    in
    Encode.object
        [ ( "id", Encode.string j.id )
        , ( "minutes", Encode.int (Search.totalMinutes startTime tour) )
        , ( "meters", Encode.int (Search.totalDistanceMeters startTime tour) )
        , ( "finish", Encode.int (Search.stops startTime tour |> List.Extra.last |> Maybe.withDefault j.startCity) )
        ]


type Msg
    = Received Decode.Value


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), Cmd.none )
        , update =
            \(Received value) model ->
                case Decode.decodeValue jobDecoder value of
                    Ok j ->
                        ( model, done (run j) )

                    Err _ ->
                        ( model, Cmd.none )
        , subscriptions = \_ -> job Received
        }
