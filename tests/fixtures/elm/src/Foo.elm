module Foo exposing (InstanceStep, InstanceStepId, advance)


type alias InstanceStepId =
    String


type alias InstanceStep =
    { id : InstanceStepId
    , label : String
    , done : Bool
    }


advance : InstanceStep -> InstanceStep
advance step =
    { step | done = True }
