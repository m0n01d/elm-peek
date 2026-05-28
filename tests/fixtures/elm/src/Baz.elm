module Baz exposing (InstanceStep, Wrapper)

-- A second declaration with the same name as one in Foo, so disambiguation
-- can be exercised.


type alias InstanceStep =
    { kind : String }


type alias Wrapper a =
    { value : a }
