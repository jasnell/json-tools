# JSON Tools

A basic implementation of the JSON Patch, Pointer and Predicate specifications.

```
gem install json-tools
````

``` ruby
require 'jsontools'
include JsonTools

my_hash = JSON.parse %Q/
  {
    "a": {
      "b": {
        "c": "123!ABC"
      }
    }
  }
/

my_patch = JSON.parse %Q!
  [
    {
      "op": "contains",
      "path": "/a/b/c",
      "value": "ABC"
    },
    {
      "op": "replace",
      "path": "/a/b/c",
      "value": 123
    }
  ]
!

patch = Patch.new_with_predicates my_patch

# create new modified hash
new_hash = patch.apply_to my_hash

# edit hash in place
patch.apply_to! my_hash
```

Additional details to come later.