module Mirah
  module JVM
    module Types
      class NullType < Type
        def initialize(types)
          super(types, types.get_mirror('java.lang.Object'))
        end

        def to_s
          "Type(null)"
        end

        def null?
          true
        end

        def compatible?(other)
          !other.primitive?
        end

        def assignable_from?(other)
          if other.respond_to?(:primitive)
            !other.primitive?
          else
            other.isError
          end
        end
      end
    end
  end
end