def parse:
  map(select(.name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+(-preview)?$")))
  | map({
      name: .name,
      is_preview: (.name | contains("-preview")),
      nums: (.name | sub("^v";"") | sub("-preview$";"") | split(".") | map(tonumber))
    });
def scalar(n): (n[0]*1000000000 + n[1]*1000000 + n[2]*1000 + n[3]);

parse
| map(select(.is_preview == $want_prev))
| ($ver | split(".") | map(tonumber)) as $w
| (if $strict then map(select(.nums[0]==$w[0] and .nums[1]==$w[1] and .nums[2]==$w[2])) else . end)
| if length==0 then [] else
    map(. + {dist: ((scalar(.nums) - scalar($w)) | if . < 0 then -. else . end)})
    | sort_by(.dist, .nums)
    | .[0:1] | .[0].name
  end
