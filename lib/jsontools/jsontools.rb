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
    
    # Raised when an error occurs during the
    # evaluation of the pointer against a 
    # given context
    class PointerError < StandardError; end
    
    def initialize path
      @parts = path.split('/').drop(1).map { |p|
          p.gsub(/\~1/, '/').gsub(/\~0/, '~') 
        }
      @last = @parts.pop
    end
    
    # Returns the last segment of the JSON Pointer
    def last; @last; end
    
    # Evaluates the pointer against the given 
    # context hash object and returns the 
    # parent. That is, if the Pointer is 
    # "/a/b/c", parent will return the object
    # referenced by "/a/b", or nil if that 
    # object does not exist.
    def parent context
      @parts.reduce(context) do |o, p| 
        o[(o.is_a?(Array) ? p.to_i : p)] 
      end
    rescue
      raise PointerError
    end
    alias :[] :parent

    # Enumerates down the pointer path, yielding
    # to the given block each name, value pair 
    # specified in the path, halting at the first
    # nil value encountered. The required block
    # will be passed two parameters. The first is 
    # the accessor name, the second is the value.
    # For instance, given the hash {'a'=>{'b'=>{'c'=>123}}},
    # and the pointer "/a/b/c", the block will be 
    # called three times, first with ['a',{'b'=>{'c'=>123}}],
    # next with ['b',{'c'=>123}], and finally with
    # ['c',123]. 
    def walk context
      p = @parts.reduce(context) do |o,p|
        n = o[(o.is_a?(Array) ? p.to_i : p)]
        yield p, n
        return if NilClass === n # exit the loop if the object is nil
        n
      end
      key = JsonTools.fix_key(p,@last)
      yield key, (!p ? nil : p[key])
    end
        
    # Returns the specific value identified by this
    # pointer, if any. Nil is returned if the path 
    # does not exist. Note that this does not differentiate
    # between explicitly null values or missing paths. 
    def value context
      parent = parent context
      parent[JsonTools.fix_key(parent,@last)] unless !parent
    end
    
    # Alternative to value that raises a PointerError
    # if the referenced path does not exist. 
    def value_with_fail context
      parent = parent context
      fail if !parent
      parent.fetch(JsonTools.fix_key(parent,@last))
    rescue
      raise PointerError
    end
    
    # True if the referenced path exists
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

    class InvalidPatchDocumentError < StandardError; end
    class FailedOperationError < StandardError; end

    def initialize ops, with_predicates=false
      # Parse JSON if necessary
      if ops.is_a?(String) || ops.respond_to?(:read)
        ops = JSON.load(ops)
      end
      fail unless Array === ops
      @ops = ops
      # Should we include the JSON Predicate operations?
      # Off by default
      extend Predicate if with_predicates
    rescue
      raise InvalidPatchDocumentError
    end
    
    # Initialize a new Patch object with 
    # JSON Predicate Operations enabled
    def self.new_with_predicates ops
      new ops, true
    end

    # Apply the patch to the given target hash
    # object. Note that the target will be 
    # modified in place and changes will not 
    # be reversable in the case of failure.
    def apply_to! target
      @ops.each_with_object(target) do |operation, target|
        op = operation['op'].to_sym if operation.key?('op')
        PATCH_OPERATIONS[op][operation, target] rescue raise 'Invalid Operation'
      end
    end
    
    # Apply the patch to a copy of the given 
    # target hash. The new, modified hash 
    # will be returned. 
    def apply_to target
      apply_to! target.json_deep_copy
    end
    
    private

    # Define the various core patch operations
    class << Patch
      
      def add params, target
        ptr = Pointer.new params['path']
        obj = ptr[target]
        fail if not (Array === obj || Hash === obj)
        if (Array === obj && ptr.last == '-') 
          obj.insert -1,params['value']
        else
          obj.insert JsonTools.fix_key(obj,ptr.last),params['value']
        end
      rescue
         raise FailedOperationError
      end
        
      def remove params, target
        ptr = Pointer.new params['path']
        return if not ptr.exists? target #it's gone, just ignore.. TODO: might still need to throw an error, but we'll skip it for now
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
        from = Pointer.new params['from']
        to = Pointer.new params['path']
        fail if !from.exists?(target) #|| to.exists?(target)
        obj = from[target]
        val = obj[JsonTools.fix_key(obj,from.last)]
        remove(({'path'=>params['path']}), target) if move # we only remove it if we're doing a move operation
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
  
  # Define the Predicate methods for use with the Patch object
  module Predicate
    
    def self.string_check params, target, &block
      ptr = Pointer.new params['path']
      return false if !ptr.exists?(target)
      val = ptr.value target
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
      val = ptr.value target
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
      val = ptr.value target
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
        val = ptr.value target
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
