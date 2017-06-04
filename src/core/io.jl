#########################
# Sampler I/O Interface #
#########################

##########
# Sample #
##########

type Sample
  weight :: Float64     # particle weight
  value :: Dict{Symbol,Any}
end

Base.getindex(s::Sample, v::Symbol) = getjuliatype(s, v)

getjuliatype(s::Sample, v::Symbol, cached_syms=nothing) = begin
  # NOTE: cached_syms is used to cache the filter entiries in svalue. This is helpful when the dimension of model is huge.
  if cached_syms == nothing
    # Get all keys associated with the given symbol
    syms = collect(filter(k -> search(string(k), string(v)*"[") != 0:-1, keys(s.value)))
  else
    syms = filter(k -> search(string(k), string(v)) != 0:-1, cached_syms)
  end
  # Map to the corresponding indices part
  idx_str = map(sym -> replace(string(sym), string(v), ""), syms)
  # Get the indexing component
  idx_comp = map(idx -> filter(str -> str != "", split(string(idx), [']','['])), idx_str)

  # Deal with v is really a symbol, e.g. :x
  if length(idx_comp) == 0
    return Base.getindex(s.value, v)
  end

  # Construct container for the frist nesting layer
  dim = length(split(idx_comp[1][1], ','))
  if dim == 1
    sample = Vector(length(unique(map(c -> c[1], idx_comp))))
  else
    d = max(map(c -> eval(parse(c[1])), idx_comp)...)
    sample = Array{Any, length(d)}(d)
  end

  # Fill sample
  for i = 1:length(syms)
    # Get indexing
    idx = eval(parse(idx_comp[i][1]))
    # Determine if nesting
    nested_dim = length(idx_comp[1]) # how many nested layers?
    if nested_dim == 1
      setindex!(sample, getindex(s.value, syms[i]), idx...)
    else  # nested case, iteratively evaluation
      v_indexed = Symbol("$v[$(idx_comp[i][1])]")
      setindex!(sample, getjuliatype(s, v_indexed, syms), idx...)
    end
  end
  sample
end

#########
# Chain #
#########

doc"""
    Chain(weight::Float64, value::Array{Sample})

A wrapper of output trajactory of samplers.

Example:

```julia
# Define a model
@model xxx begin
  ...
  return(mu,sigma)
end

# Run the inference engine
chain = sample(xxx, SMC(1000))

chain[:logevidence]   # show the log model evidence
chain[:mu]            # show the weighted trajactory for :mu
chain[:sigma]         # show the weighted trajactory for :sigma
mean(chain[:mu])      # find the mean of :mu
mean(chain[:sigma])   # find the mean of :sigma
```
"""
type Chain <: Mamba.AbstractChains
  weight  ::  Float64                 # log model evidence
  value2  ::  Array{Sample}
  value   ::  Array{Float64, 3}
  range   ::  Range{Int}
  names   ::  Vector{AbstractString}
  chains  ::  Vector{Int}
  info    ::  Dict{Symbol,Any}
end

Chain() = Chain(0, Vector{Sample}(), Array{Float64, 3}(0,0,0), 0:0,
                Vector{AbstractString}(), Vector{Int}(), Dict{Symbol,Any}())

Chain(w::Real, s::Array{Sample}) = begin
  chn = Chain()
  chn.weight = w
  chn.value2 = deepcopy(s)

  chn = flatten!(chn)
end

flatten!(chn::Chain) = begin
  ## Flatten samples into Mamba's chain type.
  local names = Array{Array{AbstractString}}(0)
  local vals  = Array{Array}(0)
  for s in chn.value2
    v, n = flatten(s)
    push!(vals, v)
    push!(names, n)
  end

  # Assuming that names[i] == names[j] for all (i,j)
  vals2 = [v[i] for v in vals, i=1:length(names[1])]
  vals2 = reshape(vals2, length(vals), length(names[1]), 1)
  c = Mamba.Chains(vals2, names = names[1])
  chn.value = c.value
  chn.range = c.range
  chn.names = c.names
  chn.chains = c.chains
  chn
end

flatten(s::Sample) = begin
  vals  = Array{Float64}(0)
  names = Array{AbstractString}(0)
  for (k, v) in s.value
    flatten(names, vals, string(k), v)
  end
  return vals, names
end
flatten(names, value :: Array{Float64}, k :: String, v) = begin
    if isa(v, Number)
      name = k
      push!(value, v)
      push!(names, name)
    elseif isa(v, Array)
      for i = eachindex(v)
        if isa(v[i], Number)
          name = k * string(ind2sub(size(v), i))
          name = replace(name, "(", "[");
          name = replace(name, ",)", "]");
          name = replace(name, ")", "]");
          isa(v[i], Void) && println(v, i, v[i])
          push!(value, Float64(v[i]))
          push!(names, name)
        elseif isa(v[i], Array)
          name = k * string(ind2sub(size(v), i))
          flatten(names, value, name, v[i])
        else
          error("Unknown var type: typeof($v[i])=$(typeof(v[i]))")
        end
      end
  else
    error("Unknown var type: typeof($v)=$(typeof(v))")
  end
end

function Base.getindex(c::Chain, v::Symbol)
  # This strange implementation is mostly to keep backward compatability.
  #  Needs some refactoring a better format for storing results is available.
  if v == :logevidence
    log(c.weight)
  elseif v==:samples
    c.value2
  elseif v==:logweights
    c[:lp]
  else
    map((s)->Base.getindex(s, v), c.value2)
  end
end

function Base.vcat(c1::Chain, args::Chain...)

  names = c1.names
  all(c -> c.names == names, args) ||
    throw(ArgumentError("chain names differ"))

  chains = c1.chains
  all(c -> c.chains == chains, args) ||
    throw(ArgumentError("sets of chains differ"))

  value2 = cat(1, c1.value2, map(c -> c.value2, args)...)
  Chain(0, value2)
end

save!(c::Chain, spl::Sampler, model::Function, vi::VarInfo) = begin
  c.info[:spl] = spl
  c.info[:model] = model
  c.info[:vi] = vi
end
