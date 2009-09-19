require 'jruby'

module Duby
  module Transform
    class Error < Exception
      def initialize(msg, position)
        super(msg)
        @position = position
      end
    end
  end
  TransformError = Transform::Error

  module AST
    def parse(src)
      JRuby.parse(src).transform(nil)
    end
    module_function :parse

    # reload 
    module Java::OrgJrubyAst
      class Node
        def transform(parent)
          # default behavior is to raise, to expose missing nodes
          raise TransformError.new("Unsupported syntax: #{self}", position)
        end
        
        def line_number
          position.start_line + 1 rescue nil
        end
      end

      class ArgsNode
        def transform(parent)
          Arguments.new(parent, line_number) do |args_node|
            arg_list = args.child_nodes.map do |node|
              RequiredArgument.new(args_node, node.line_number, node.name)
              # argument nodes will have type soon
              #RequiredArgument.new(args_node, node.name, node.type)
            end if args

            opt_list = opt_args.child_nodes.map do |node|
              OptionalArgument.new(args_node, node.line_number) {|opt_arg| [node.transform(opt_arg)]}
            end if opt_args

            rest_arg = RestArgument.new(args_node, rest_arg_node.line_number, rest_arg_node.name) if rest_arg_node

            block_arg = BlockArgument.new(args_node, block_arg_node.line_number, block_arg_node.name) if block_arg_node

            [arg_list, opt_list, rest_arg, block_arg]
          end
        end
      end

      class ArrayNode
        def transform(parent)
          Array.new(parent, line_number) do |array|
            child_nodes.map {|child| child.transform(array)}
          end
        end
      end

      class AttrAssignNode
        def transform(parent)
          case name
          when '[]='
            Call.new(parent, line_number, name) do |call|
              [
                receiver_node.transform(call),
                args_node ? args_node.child_nodes.map {|arg| arg.transform(call)} : [],
                nil
              ]
            end
          else
            new_name = name[0..-2] + '_set'
            Call.new(parent, line_number, new_name) do |call|
              [
                receiver_node.transform(call),
                args_node ? args_node.child_nodes.map {|arg| arg.transform(call)} : [],
                nil
              ]
            end
          end
        end
      end

      class BeginNode
        def transform(parent)
          body_node.transform(parent)
        end
      end

      class BlockNode
        def transform(parent)
          Body.new(parent, line_number) do |body|
            child_nodes.map {|child| child.transform(body)}
          end
        end
      end

      class ClassNode
        def transform(parent)
          ClassDefinition.new(parent, line_number, cpath.name) do |class_def|
            [
              super_node ? super_node.transform(class_def) : nil,
              body_node ? body_node.transform(class_def) : nil
            ]
          end
        end
      end

      class CallNode
        def transform(parent)
          actual_name = name
          case actual_name
          when '[]'
            # could be array instantiation
            case receiver_node
            when VCallNode
              case receiver_node.name
              when 'boolean', 'byte', 'short', 'char', 'int', 'long', 'float', 'double'
                return EmptyArray.new(parent, line_number, AST::type(receiver_node.name)) do |array|
                  args_node.get(0).transform(array)
                end
              # TODO look for imported, lower case class names
              end
            when ConstNode
              return EmptyArray.new(parent, line_number, AST::type(receiver_node.name)) do |array|
                args_node.get(0).transform(array)
              end
            end
          when /=$/
            actual_name = name[0..-2] + '_set'
          end
          
          Call.new(parent, line_number, name) do |call|
            [
              receiver_node.transform(call),
              args_node ? args_node.child_nodes.map {|arg| arg.transform(call)} : [],
              iter_node ? iter_node.transform(call) : nil
            ]
          end
        end

        def type_reference(parent)
          if name == "[]"
            # array type, top should be a constant; find the rest
            array = true
            elements = []
          else
            array = false
            elements = [name]
          end

          receiver = receiver_node

          loop do
            case receiver
            when ConstNode
              elements << receiver_node.name
              break
            when CallNode
              elements.unshift(receiver.name)
              receiver = receiver.receiver_node
            when SymbolNode
              elements.unshift(receiver.name)
              break
            when VCallNode
              elements.unshift(receiver.name)
              break
            end
          end

          # join and load
          class_name = elements.join(".")
          AST::type(class_name, array)
        end
      end

      class Colon2Node
      end

      class ConstNode
        def transform(parent)
          Constant.new(parent, line_number, name)
        end

        def type_reference(parent)
          AST::type(name, false, false)
        end
      end

      class DefnNode
        def transform(parent)
          actual_name = name
          if name =~ /=$/
            actual_name = name[0..-2] + '_set'
          end
          MethodDefinition.new(parent, line_number, actual_name) do |defn|
            signature = {:return => nil}

            # TODO: Disabled until parser supports it
            if args_node && args_node.args && TypedArgumentNode === args_node.args[0]
              args_node.args.child_nodes.each do |arg|
                signature[arg.name.intern] = arg.type_node.type_reference(parent)
              end
            elsif body_node
              first_node = body_node[0]
              first_node = first_node.next_node while NewlineNode === first_node
              if HashNode === first_node
                signature = first_node.signature(defn)
              end
            end
            [
              signature,
              args_node ? args_node.transform(defn) : nil,
              body_node ? body_node.transform(defn) : nil
            ]
          end
        end
      end

      class DefsNode
        def transform(parent)
          actual_name = name
          if name =~ /=$/
            actual_name = name[0..-2] + '_set'
          end
          StaticMethodDefinition.new(parent, line_number, actual_name) do |defn|
            signature = {:return => nil}

            # TODO: Disabled until parser supports it
            if args_node && args_node.args && TypedArgumentNode === args_node.args[0]
              args_node.args.child_nodes.each do |arg|
                signature[arg.name.intern] = arg.type_node.type_reference(parent)
              end
            elsif body_node
              first_node = body_node[0]
              first_node = first_node.next_node while NewlineNode === first_node
              if HashNode === first_node
                signature = first_node.signature(defn)
              end
            end
            [
              signature,
              args_node ? args_node.transform(defn) : nil,
              body_node ? body_node.transform(defn) : nil
            ]
          end
        end
      end
      
      class FalseNode
        def transform(parent)
          Boolean.new(parent, line_number, false)
        end
      end

      class FCallNode
        def transform(parent)
          # TODO This should probably be pluggable
          case name
          when "import"
            case args_node
            when ArrayNode
              case args_node.size
              when 1
                case args_node.get(0)
                when StrNode
                  long = args_node.get(0).value
                  short = long[(long.rindex('.') + 1)..-1]
                when CallNoArgNode
                  node = args_node.get(0)
                  pieces = [node.name]
                  while node.kind_of? CallNode
                    node = node.receiver_node
                    pieces << node.name
                  end
                  long = pieces.reverse.join '.'
                  short = pieces[0]
                when CallOneArgNode
                  arg = args_node.get(0).args_node.get(0)
                  unless FCallOneArgNode === arg && arg.name == 'as'
                    raise "unknown import syntax at #{self}"
                  end
                  short = arg.args_node.get(0).name
                  node = args_node.get(0)
                  pieces = [node.name]
                  while node.kind_of? CallNode
                    node = node.receiver_node
                    pieces << node.name
                  end
                  long = pieces.reverse.join '.'
                else
                  raise "unknown import syntax at #{self}"
                end
              when 2
                short = args_node.child_nodes[0].value
                long = args_node.child_nodes[1].value
              else
                raise "unknown import syntax at #{self}"
              end
            else
              raise "unknown import syntax at #{self}"
            end
            Import.new(parent, line_number, short, long)
          when "puts"
            PrintLine.new(parent, line_number) do |println|
              args_node ? args_node.child_nodes.map {|arg| arg.transform(println)} : []
            end
          when "null"
            Null.new(parent, line_number)
          else
            FunctionalCall.new(parent, line_number, name) do |call|
              [
                args_node ? args_node.child_nodes.map {|arg| arg.transform(call)} : [],
                iter_node ? iter_node.transform(call) : nil
              ]
            end
          end
        end
      end

      class FixnumNode
        def transform(parent)
          AST::fixnum(parent, line_number, value)
        end
      end

      class FloatNode
        def transform(parent)
          AST::float(parent, line_number, value)
        end
      end

      class HashNode
        def transform(parent)
          @declaration ||= false

          if @declaration
            Noop.new(parent, line_number)
          else
            super
          end
        end

        # Create a signature definition using a literal hash syntax
        def signature(parent)
          # flag this as a declaration, so it transforms to a noop
          @declaration = true

          arg_types = {:return => nil}

          list = list_node.child_nodes.to_a
          list.each_index do |index|
            if index % 2 == 0
              if SymbolNode === list[index] && list[index].name == 'return'
                arg_types[:return] = list[index + 1].type_reference(parent)
              else
                arg_types[list[index].name.intern] = list[index + 1].type_reference(parent)
              end
            end
          end
          return arg_types
        end
      end

      class IfNode
        def transform(parent)
          If.new(parent, line_number) do |iff|
            [
              Condition.new(iff, condition.line_number) {|cond| [condition.transform(cond)]},
              then_body ? then_body.transform(iff) : nil,
              else_body ? else_body.transform(iff) : nil
            ]
          end
        end
      end

      class NilImplicitNode
        def transform(parent)
          Noop.new(parent, line_number)
        end
      end

      class NilNode
        def transform(parent)
          Null.new(parent, line_number)
        end
      end

      class InstAsgnNode
        def transform(parent)
          case value_node
          when SymbolNode, ConstNode
            FieldDeclaration.new(parent, line_number, name) {|field_decl| [value_node.type_reference(field_decl)]}
          else
            FieldAssignment.new(parent, line_number, name) {|field| [value_node.transform(field)]}
          end
        end
      end

      class InstVarNode
        def transform(parent)
          Field.new(parent, line_number, name)
        end
      end

      class LocalAsgnNode
        def transform(parent)
          case value_node
          when SymbolNode, ConstNode
            LocalDeclaration.new(parent, line_number, name) {|local_decl| [value_node.type_reference(local_decl)]}
          else
            LocalAssignment.new(parent, line_number, name) {|local| [value_node.transform(local)]}
          end
        end
      end

      class LocalVarNode
        def transform(parent)
          Local.new(parent, line_number, name)
        end
      end

      class ModuleNode
      end

      class NewlineNode
        def transform(parent)
          actual = next_node.transform(parent)
          actual.newline = true
          actual
        end

        # newlines are bypassed during signature transformation
        def signature(parent)
          next_node.signature(parent)
        end
      end

      class NotNode
        def transform(parent)
          Not.new(parent, line_number) {|nott| [condition_node.transform(nott)]}
        end
      end

      class ReturnNode
        def transform(parent)
          Return.new(parent, line_number) do |ret|
            [value_node.transform(ret)]
          end
        end
      end

      class RootNode
        def transform(parent)
          Script.new(parent, line_number) {|script| [child_nodes[0].transform(script)]}
        end
      end

      class SelfNode
      end

      class StrNode
        def transform(parent)
          String.new(parent, line_number, value)
        end
        
        def type_reference(parent)
          AST::type(value)
        end
      end

      class SymbolNode
        def type_reference(parent)
          AST::type(name)
        end
      end
      
      class TrueNode
        def transform(parent)
          Boolean.new(parent, line_number, true)
        end
      end
      
      class TypedArgumentNode
      end

      class VCallNode
        def transform(parent)
          FunctionalCall.new(parent, line_number, name) do |call|
            [
              [],
              nil
            ]
          end
        end
      end

      class WhileNode
        def transform(parent)
          Loop.new(parent, line_number, evaluate_at_start, false) do |loop|
            [
              Condition.new(loop, condition_node.line_number) {|cond| [condition_node.transform(cond)]},
              body_node.transform(loop)
            ]
          end
        end
      end

      class UntilNode
        def transform(parent)
          Loop.new(parent, line_number, evaluate_at_start, true) do |loop|
            [
              Condition.new(loop, condition_node.line_number) {|cond| [condition_node.transform(cond)]},
              body_node.transform(loop)
            ]
          end
        end
      end
    end
  end
end
