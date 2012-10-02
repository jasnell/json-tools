####################################
# JSON Tools                       # 
#   Implementation of JSON Patch,  #
#   Pointer and Predicates         #
#                                  #
# Author: James M Snell            #
#         (jasnell@gmail.com)      #
# License: Apache v2.0             #
####################################

require 'json'

class Hash
  # A fairly inefficient means of 
  # generating a deep copy of the 
  # hash; but it ensures that our 
  # hash conforms to the JSON spec
  # and does not contain any cycles
  def json_deep_copy
    JSON.parse to_json
  end
  
  def insert loc,val
    self[loc] = val
  end
  
  def delete_at loc
    self.delete loc
  end
  
end

module JsonTools

  def self.fix_key obj, key
    if Array === obj
      idx = Integer key
      fail if not (0...obj.length).cover? idx
      key = idx
    end
    key
  end

  class Pointer
    
    class PointerError < StandardError 
    end
    
    def initialize path
      @parts = path.split('/').drop(1).map { |p|
          p.gsub(/\~1/, '/').gsub(/\~0/, '~') 
        }
      @last = @parts.pop
    end
    
    def last 
      @last
    end
    
    def parent context
      @parent ||= @parts.reduce(context) do |o, p| 
        o[(o.is_a?(Array) ? p.to_i : p)] 
      end
    rescue
      raise PointerError
    end
    alias :[] :parent
    
    def exists? context
      p = parent context
      if Array === p
        (0...p.length).cover? Integer(@last)
      else
        p.has_key? @last
      end
    rescue
      false
    end

  end

  class Patch
    
    PATCH_OPERATIONS = {}

    class InvalidPatchDocumentError < StandardError
    end

    class FailedOperationError < StandardError
    end

    def initialize ops, with_predicates=false
      if ops.is_a?(String) || ops.respond_to?(:read)
        ops = JSON.load(ops)
      end
      fail unless Array === ops
      @ops = ops
      extend Predicate if with_predicates
    rescue
      raise InvalidPatchDocumentError
    end
    
    def self.new_with_predicates ops
      new ops, true
    end

    def apply_to! target
      @ops.each_with_object(target) do |operation, target|
        op = operation['op'].to_sym if operation.key?('op')
        PATCH_OPERATIONS[op][operation, target] rescue raise 'Invalid Operation'
      end
    end
    
    def apply_to target
      apply_to! target.json_deep_copy
    end
    
    private

    class << Patch
      def add params, target
        ptr = Pointer.new params['path']
        fail if ptr.exists? target
        obj = ptr[target]
        fail if not (Array === obj || Hash === obj)
        obj.insert JsonTools.fix_key(obj,ptr.last),params['value']
      rescue
        raise FailedOperationError
      end
        
      def remove params, target
        ptr = Pointer.new params['path']
        return if not ptr.exists? target #it's gone, just ignore.. TODO: might still need to throw an error
        obj  = ptr[target]
        obj.delete_at JsonTools.fix_key(obj,ptr.last)
      rescue
        raise FailedOperationError
      end

      def move params, target
        move_or_copy params, target, true
      end
    
      def copy params, target
        move_or_copy params, target, false
      end
    
      def move_or_copy params, target, move=false 
        from = Pointer.new params['path']
        to = Pointer.new params['to']
        fail if !from.exists?(target) || to.exists?(target)
        obj = from[target]
        val = obj[JsonTools.fix_key(obj,from.last)]
        remove(({'path'=>params['path']}), target) if move
        add ({'path'=>params['to'],'value'=>val}), target
      rescue
        raise FailedOperationError
      end

      def replace params, target
        ptr = Pointer.new params['path']
        fail if not ptr.exists? target
        obj = ptr[target]
        obj[JsonTools.fix_key(obj,ptr.last)] = params['value']
      rescue
        raise FailedOperationError
      end

      def test params, target
        ptr = Pointer.new(params['path'])
        fail if not ptr.exists? target
        obj = ptr[target]
        val = obj[JsonTools.fix_key(obj,ptr.last)]
        fail unless val == params['value']
      rescue
        raise FailedOperationError
      end

    end # END EIGENCLASS DEFINITION
    
    # Specify the Patch Operations
    [:add,:remove,:replace,:move,:copy,:test].each { |x| PATCH_OPERATIONS[x] = lambda(&method(x)) }
    
    public 
    
    def register_op sym, op
      PATCH_OPERATIONS[sym] = op
    end
    
  end # End Patch Class
  
  module Predicate
    
    def self.string_check params, target, &block
      ptr = Pointer.new params['path']
      return false if !ptr.exists?(target)
      parent, key = ptr[target], ptr.last
      key = JsonTools.fix_key(parent, key)
      val = parent[key]
      return false unless String === val
      ignore_case = params['ignore_case']
      test_val = params['value']
      if ignore_case
        test_val.upcase!
        val.upcase!
      end
      yield val, test_val
    end
    
    def self.number_check params, target, &block
      ptr = Pointer.new params['path']
      return false if !ptr.exists?(target)
      parent, key = ptr[target], ptr.last
      key = JsonTools.fix_key(parent, key)
      val = parent[key]
      test_val = params['value']
      return false unless (Numeric === val && Numeric === test_val)
      yield val, test_val
    end
    
    def self.contains params, target
      string_check(params,target) {|x,y| x.include? y }
    end
    
    def self.defined params, target
      ptr = Pointer.new params['path']
      ptr.exists?(target)
    end
    
    def self.ends params, target
      string_check(params,target) {|x,y| x.end_with? y }
    end
    
    def self.matches params, target
      ptr = Pointer.new params['path']
      return false if !ptr.exists?(target)
      parent, key = ptr[target], ptr.last
      key = JsonTools.fix_key(parent, key)
      val = parent[key]
      return false unless String === val
      ignore_case = params['ignore_case']
      test_val = params['value']
      regex = ignore_case ? Regexp.new(test_val, Regexp::IGNORECASE) : Regexp.new(test_val)
      regex.match val
    end
    
    def self.less params, target
      number_check(params,target) {|x,y| x < y}
    end
    
    def self.more params, target
      number_check(params,target) {|x,y| x > y}
    end
    
    def self.starts params, target
      string_check(params,target) {|x,y| x.start_with? y }
    end
    
    def self.type params, target
      ptr = Pointer.new params['path']
      test_val = params['value']
      if !ptr.exists? target
        test_val == 'undefined'
      else
        return false if !ptr.exists?(target)
        parent, key = ptr[target], ptr.last
        key = JsonTools.fix_key(parent, key)
        val = parent[key]
        case test_val
        when 'number'
          Numeric === val
        when 'string'
          String === val
        when 'boolean'
          TrueClass === val || FalseClass === val
        when 'object'
          Hash === val
        when 'array'
          Array === val
        when 'null'
          NilClass === val
        else 
          false
        end
      end
    end
    
    def self.undefined params, target
      ptr = Pointer.new params['path']
      !ptr.exists?(target)
    end
    
    def self.and params, target
      preds = params['apply']
      return false unless preds.all? {|pred| 
        op = pred['op'].to_sym
        PREDICATES[op][pred,target] rescue return false
      }
      true
    end
    
    def self.not params, target
      preds = params['apply']
      return false unless preds.none? {|pred| 
        op = pred['op'].to_sym
        PREDICATES[op][pred,target] rescue return false
      }
      true
    end
    
    def self.or params, target
      preds = params['apply']
      return false unless preds.any? {|pred| 
        op = pred['op'].to_sym
        PREDICATES[op][pred,target] rescue return false
      }
      true
    end
    
    PREDICATES = {}
    [:contains, :defined, :ends, :less,
       :matches, :more, :starts, :type,
       :undefined, :and, :not, :or].each {|x|
        PREDICATES[x] = lambda(&method(x))
      }
      
    def self.extended other
      
      PREDICATES.each_pair {|x,y| 
        other.register_op x, ->(params,target) {
          raise Patch::FailedOperationError unless y.call params,target
        }
      }
      
    end
  end
  
end # End Module
