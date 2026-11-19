module Guests exposing (Model, Msg, init, poll, update, viewPost)

{-| Likes and comments under each post on /live, from guests who signed in
with an emailed code at api.mctrot.nyc/account (recorder/api/src/guests/).

Its own module so the feature comes out cleanly: Live.elm only keeps a
Model, forwards Msgs, and calls viewPost under each post. While the server
has no guest routes (a 404, or no answer), nothing is shown at all.

Every request carries the guest's cookie for api.mctrot.nyc
(Http.riskyRequest: "with credentials"); the server only allows that
from the site's own origin.

-}

import Dict exposing (Dict)
import Html exposing (Html)
import Html.Attributes as Attr
import Html.Events as Events
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Url



-- MODEL


type Model
    = Off Config
    | On Config Feed Ui


type alias Config =
    { api : String }


{-| GET /guests/feed: who's signed in, and every post's likes and
comments as they see them.
-}
type alias Feed =
    { me : Maybe Me
    , accountUrl : String
    , posts : Dict String Social
    }


type alias Me =
    { displayName : Maybe String
    , complete : Bool
    }


type alias Social =
    { likes : Int
    , liked : Bool
    , comments : List Comment
    , pending : List Pending
    }


type alias Comment =
    { id : Int
    , name : String
    , link : Maybe String
    , text : String
    , mine : Bool
    }


type alias Pending =
    { id : Int
    , text : String
    }


{-| What's being typed, per post; the comment being reported and why; a
short note under a post ("Sent: waiting for approval").
-}
type alias Ui =
    { drafts : Dict String String
    , open : Maybe String
    , reporting : Maybe ( Int, String )
    , notes : Dict String String
    , reported : List Int
    }


emptySocial : Social
emptySocial =
    { likes = 0, liked = False, comments = [], pending = [] }


emptyUi : Ui
emptyUi =
    { drafts = Dict.empty, open = Nothing, reporting = Nothing, notes = Dict.empty, reported = [] }


init : String -> ( Model, Cmd Msg )
init api =
    ( Off { api = api }, fetchFeed api )


poll : Model -> Cmd Msg
poll model =
    fetchFeed (configOf model).api


configOf : Model -> Config
configOf model =
    case model of
        Off config ->
            config

        On config _ _ ->
            config



-- UPDATE


type Msg
    = GotFeed (Result Http.Error Feed)
    | ToggleLike String Bool
    | OpenComment String
    | Draft String String
    | SendComment String
    | Sent String (Result Http.Error ())
    | DeletePending Int
    | StartReport Int
    | ReportReason String
    | SendReport
    | CancelReport
    | Reported Int (Result Http.Error ())
    | Done (Result Http.Error ())


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case ( msg, model ) of
        ( GotFeed (Ok feed), On config _ ui ) ->
            ( On config feed ui, Cmd.none )

        ( GotFeed (Ok feed), Off config ) ->
            ( On config feed emptyUi, Cmd.none )

        ( GotFeed (Err (Http.BadStatus 404)), _ ) ->
            -- Guests are off on this server.
            ( Off (configOf model), Cmd.none )

        ( GotFeed (Err _), _ ) ->
            -- Keep what's shown; the next poll retries.
            ( model, Cmd.none )

        ( ToggleLike postId liked, On config feed ui ) ->
            -- Shown at once; the next feed has the real count.
            let
                social =
                    socialOf postId feed

                changed =
                    { social
                        | liked = liked
                        , likes =
                            social.likes
                                + (if liked then
                                    1

                                   else
                                    -1
                                  )
                    }
            in
            ( On config { feed | posts = Dict.insert postId changed feed.posts } ui
            , send config.api
                "POST"
                "/guests/likes"
                (Encode.object [ ( "postId", Encode.string postId ), ( "liked", Encode.bool liked ) ])
                Done
            )

        ( OpenComment postId, On config feed ui ) ->
            ( On config feed { ui | open = Just postId }, Cmd.none )

        ( Draft postId text, On config feed ui ) ->
            ( On config feed { ui | drafts = Dict.insert postId text ui.drafts }, Cmd.none )

        ( SendComment postId, On config feed ui ) ->
            case String.trim (Dict.get postId ui.drafts |> Maybe.withDefault "") of
                "" ->
                    ( model, Cmd.none )

                text ->
                    ( On config feed { ui | notes = Dict.insert postId "Sending…" ui.notes }
                    , send config.api
                        "POST"
                        "/guests/comments"
                        (Encode.object [ ( "postId", Encode.string postId ), ( "text", Encode.string text ) ])
                        (Sent postId)
                    )

        ( Sent postId (Ok ()), On config feed ui ) ->
            ( On config
                feed
                { ui
                    | drafts = Dict.remove postId ui.drafts
                    , open = Nothing
                    , notes = Dict.insert postId "Sent! It shows here once it's approved." ui.notes
                }
            , fetchFeed config.api
            )

        ( Sent postId (Err error), On config feed ui ) ->
            ( On config feed { ui | notes = Dict.insert postId (problem error) ui.notes }, Cmd.none )

        ( DeletePending id, On config _ _ ) ->
            ( model, send config.api "DELETE" ("/guests/comments/" ++ String.fromInt id) Encode.null Done )

        ( StartReport id, On config feed ui ) ->
            ( On config feed { ui | reporting = Just ( id, "" ) }, Cmd.none )

        ( ReportReason reason, On config feed ui ) ->
            ( On config feed { ui | reporting = Maybe.map (\( id, _ ) -> ( id, reason )) ui.reporting }, Cmd.none )

        ( CancelReport, On config feed ui ) ->
            ( On config feed { ui | reporting = Nothing }, Cmd.none )

        ( SendReport, On config _ ui ) ->
            case ui.reporting of
                Just ( id, reason ) ->
                    if String.isEmpty (String.trim reason) then
                        ( model, Cmd.none )

                    else
                        ( model
                        , send config.api
                            "POST"
                            "/guests/reports"
                            (Encode.object [ ( "commentId", Encode.int id ), ( "reason", Encode.string (String.trim reason) ) ])
                            (Reported id)
                        )

                Nothing ->
                    ( model, Cmd.none )

        ( Reported id (Ok ()), On config feed ui ) ->
            ( On config feed { ui | reporting = Nothing, reported = id :: ui.reported }, Cmd.none )

        ( Reported _ (Err _), _ ) ->
            ( model, Cmd.none )

        ( Done _, On config _ _ ) ->
            ( model, fetchFeed config.api )

        _ ->
            ( model, Cmd.none )


problem : Http.Error -> String
problem error =
    case error of
        Http.BadStatus 401 ->
            "Sign in again to comment."

        Http.BadStatus 429 ->
            "Slow down: too many comments. Try again in a few minutes."

        Http.BadStatus 400 ->
            "Comments can be up to 500 characters."

        _ ->
            "Couldn't send. Check your connection and try again."


socialOf : String -> Feed -> Social
socialOf postId feed =
    Dict.get postId feed.posts |> Maybe.withDefault emptySocial



-- HTTP


fetchFeed : String -> Cmd Msg
fetchFeed api =
    Http.riskyRequest
        { method = "GET"
        , headers = []
        , url = api ++ "/guests/feed"
        , body = Http.emptyBody
        , expect = Http.expectJson GotFeed feedDecoder
        , timeout = Just 15000
        , tracker = Nothing
        }


send : String -> String -> String -> Encode.Value -> (Result Http.Error () -> Msg) -> Cmd Msg
send api method path body toMsg =
    Http.riskyRequest
        { method = method
        , headers = []
        , url = api ++ path
        , body =
            if body == Encode.null then
                Http.emptyBody

            else
                Http.jsonBody body
        , expect = Http.expectWhatever toMsg
        , timeout = Just 15000
        , tracker = Nothing
        }


feedDecoder : Decoder Feed
feedDecoder =
    Decode.map3 Feed
        (Decode.field "me"
            (Decode.nullable
                (Decode.map2 Me
                    (Decode.field "displayName" (Decode.nullable Decode.string))
                    (Decode.field "complete" Decode.bool)
                )
            )
        )
        (Decode.field "accountUrl" Decode.string)
        (Decode.field "posts" (Decode.dict socialDecoder))


socialDecoder : Decoder Social
socialDecoder =
    Decode.map4 Social
        (Decode.field "likes" Decode.int)
        (Decode.field "liked" Decode.bool)
        (Decode.field "comments"
            (Decode.list
                (Decode.map5 Comment
                    (Decode.field "id" Decode.int)
                    (Decode.field "name" Decode.string)
                    (Decode.field "link" (Decode.nullable Decode.string))
                    (Decode.field "text" Decode.string)
                    (Decode.field "mine" Decode.bool)
                )
            )
        )
        (Decode.field "pending"
            (Decode.list (Decode.map2 Pending (Decode.field "id" Decode.int) (Decode.field "text" Decode.string)))
        )



-- VIEW


{-| Under one post: the like button, approved comments, the guest's own
waiting ones, and a way to comment. `back` is this page's address, for
after signing in.
-}
viewPost : String -> String -> Model -> Html Msg
viewPost back postId model =
    case model of
        Off _ ->
            Html.text ""

        On _ feed ui ->
            let
                social =
                    socialOf postId feed

                signInUrl =
                    feed.accountUrl ++ "?back=" ++ Url.percentEncode back

                canAct =
                    Maybe.map .complete feed.me |> Maybe.withDefault False
            in
            Html.div [ Attr.class "guest" ]
                [ Html.div [ Attr.class "guest-bar" ]
                    [ if canAct then
                        Html.button
                            [ Attr.class "guest-like"
                            , Attr.classList [ ( "guest-liked", social.liked ) ]
                            , Attr.attribute "aria-pressed" (boolText social.liked)
                            , Events.onClick (ToggleLike postId (not social.liked))
                            ]
                            [ Html.text (heart social.liked ++ likesText social.likes) ]

                      else
                        Html.a [ Attr.class "guest-like", Attr.href signInUrl, Attr.title "Sign in to like" ]
                            [ Html.text (heart False ++ likesText social.likes) ]
                    , if canAct then
                        if ui.open == Just postId then
                            Html.text ""

                        else
                            Html.button [ Attr.class "guest-link", Events.onClick (OpenComment postId) ] [ Html.text "Comment" ]

                      else
                        Html.a [ Attr.class "guest-link", Attr.href signInUrl ]
                            [ Html.text
                                (if feed.me == Nothing then
                                    "Sign in to like and comment"

                                 else
                                    "Finish signing up to comment"
                                )
                            ]
                    ]
                , if List.isEmpty social.comments && List.isEmpty social.pending then
                    Html.text ""

                  else
                    Html.ul [ Attr.class "guest-comments" ]
                        (List.map (viewComment ui) social.comments
                            ++ List.map viewPending social.pending
                        )
                , if canAct && ui.open == Just postId then
                    viewComposer postId (Dict.get postId ui.drafts |> Maybe.withDefault "")

                  else
                    Html.text ""
                , case Dict.get postId ui.notes of
                    Just note ->
                        Html.p [ Attr.class "guest-note", Attr.attribute "role" "status" ] [ Html.text note ]

                    Nothing ->
                        Html.text ""
                ]


viewComment : Ui -> Comment -> Html Msg
viewComment ui comment =
    Html.li [ Attr.class "guest-comment" ]
        [ Html.strong []
            [ case comment.link of
                Just link ->
                    Html.a [ Attr.href link, Attr.rel "nofollow ugc noopener", Attr.target "_blank" ] [ Html.text comment.name ]

                Nothing ->
                    Html.text comment.name
            ]
        , Html.text " "
        , Html.span [ Attr.class "guest-comment-text" ] [ Html.text comment.text ]
        , if comment.mine then
            Html.text ""

          else if List.member comment.id ui.reported then
            Html.span [ Attr.class "guest-meta" ] [ Html.text " · Reported, thanks" ]

          else
            case ui.reporting of
                Just ( id, reason ) ->
                    if id == comment.id then
                        Html.form [ Attr.class "guest-report", Events.onSubmit SendReport ]
                            [ Html.input
                                [ Attr.placeholder "What's wrong with it?"
                                , Attr.value reason
                                , Attr.maxlength 500
                                , Events.onInput ReportReason
                                , Attr.attribute "aria-label" "Why report this comment"
                                ]
                                []
                            , Html.button [ Attr.type_ "submit" ] [ Html.text "Report" ]
                            , Html.button [ Attr.type_ "button", Attr.class "guest-link", Events.onClick CancelReport ] [ Html.text "Cancel" ]
                            ]

                    else
                        reportButton comment.id

                Nothing ->
                    reportButton comment.id
        ]


reportButton : Int -> Html Msg
reportButton id =
    Html.button [ Attr.class "guest-link guest-meta", Events.onClick (StartReport id) ] [ Html.text "Report" ]


viewPending : Pending -> Html Msg
viewPending pending =
    Html.li [ Attr.class "guest-comment guest-pending" ]
        [ Html.span [ Attr.class "guest-comment-text" ] [ Html.text pending.text ]
        , Html.span [ Attr.class "guest-meta" ] [ Html.text " · Waiting for approval · " ]
        , Html.button [ Attr.class "guest-link guest-meta", Events.onClick (DeletePending pending.id) ] [ Html.text "Delete" ]
        ]


viewComposer : String -> String -> Html Msg
viewComposer postId draft =
    Html.form [ Attr.class "guest-composer", Events.onSubmit (SendComment postId) ]
        [ Html.textarea
            [ Attr.value draft
            , Attr.maxlength 500
            , Attr.placeholder "Say something nice"
            , Attr.attribute "aria-label" "Your comment"
            , Events.onInput (Draft postId)
            ]
            []
        , Html.div [ Attr.class "guest-composer-row" ]
            [ Html.span [ Attr.class "guest-meta" ] [ Html.text "Comments appear once approved." ]
            , Html.button [ Attr.type_ "submit" ] [ Html.text "Send" ]
            ]
        ]


heart : Bool -> String
heart liked =
    if liked then
        "♥"

    else
        "♡"


likesText : Int -> String
likesText n =
    if n == 0 then
        ""

    else
        " " ++ String.fromInt n


boolText : Bool -> String
boolText b =
    if b then
        "true"

    else
        "false"


