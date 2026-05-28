module Bar exposing (Status(..), describe)


type Status
    = Pending
    | Running
    | Done


describe : Status -> String
describe status =
    case status of
        Pending ->
            "waiting"

        Running ->
            "in progress"

        Done ->
            "complete"
