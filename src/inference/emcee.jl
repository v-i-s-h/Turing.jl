###
### Sampler states
###

struct Emcee{space, E<:AMH.Ensemble} <: InferenceAlgorithm
    ensemble::E
end

function Emcee(n_walkers::Int, stretch_length=2.0)
    # Note that the proposal distribution here is just a Normal(0,1)
    # because we do not need AdvancedMH to know the proposal for
    # ensemble sampling.
    prop = AMH.StretchProposal(nothing, stretch_length)
    ensemble = AMH.Ensemble(n_walkers, prop)
    return Emcee{(), typeof(ensemble)}(ensemble)
end

struct EmceeState{V<:AbstractVarInfo,S}
    vi::V
    states::S
end

function AbstractMCMC.step(
    rng::Random.AbstractRNG,
    model::Model,
    spl::Sampler{<:Emcee};
    resume_from = nothing,
    init_params = nothing,
    kwargs...
)
    if resume_from !== nothing
        state = loadstate(resume_from)
        return AbstractMCMC.step(rng, model, spl, state; kwargs...)
    end

    # Sample from the prior
    n = spl.alg.ensemble.n_walkers
    vis = [VarInfo(rng, model, SampleFromPrior()) for _ in 1:n]

    # Update the parameters if provided.
    if init_params !== nothing
        length(init_params) == n || throw(
            ArgumentError("initial parameters have to be specified for each walker")
        )
        vis = map(vis, init_params) do vi, init
            vi = DynamicPPL.initialize_parameters!!(vi, init, spl, model)

            # Update log joint probability.
            last(DynamicPPL.evaluate!!(model, rng, vi, SampleFromPrior()))
        end
    end

    # Compute initial transition and states.
    transition = map(Transition, vis)

    # TODO: Make compatible with immutable `AbstractVarInfo`.
    state = EmceeState(
        vis[1],
        map(vis) do vi
            vi = DynamicPPL.link!!(vi, spl, model)
            AMH.Transition(vi[spl], getlogp(vi))
        end
    )

    return transition, state
end

function AbstractMCMC.step(
    rng::AbstractRNG,
    model::Model,
    spl::Sampler{<:Emcee},
    state::EmceeState;
    kwargs...
)
    # Generate a log joint function.
    vi = state.vi
    densitymodel = AMH.DensityModel(Turing.LogDensityFunction(vi, model, SampleFromPrior(), DynamicPPL.DefaultContext()))

    # Compute the next states.
    states = last(AbstractMCMC.step(rng, densitymodel, spl.alg.ensemble, state.states))

    # Compute the next transition and state.
    transition = map(states) do _state
        vi = setindex!!(vi, _state.params, spl)
        vi = DynamicPPL.invlink!!(vi, spl, model)
        t = Transition(tonamedtuple(vi), _state.lp)
        vi = DynamicPPL.link!!(vi, spl, model)
        return t
    end
    newstate = EmceeState(vi, states)

    return transition, newstate
end

function AbstractMCMC.bundle_samples(
    samples::Vector{<:Vector},
    model::AbstractModel,
    spl::Sampler{<:Emcee},
    state::EmceeState,
    chain_type::Type{MCMCChains.Chains};
    save_state = false,
    sort_chain = false,
    discard_initial = 0,
    thinning = 1,
    kwargs...
)
    # Convert transitions to array format.
    # Also retrieve the variable names.
    params_vec = map(_params_to_array, samples)

    # Extract names and values separately.
    nms = params_vec[1][1]
    vals_vec = [p[2] for p in params_vec]

    # Get the values of the extra parameters in each transition.
    extra_vec = map(get_transition_extras, samples)

    # Get the extra parameter names & values.
    extra_params = extra_vec[1][1]
    extra_values_vec = [e[2] for e in extra_vec]

    # Extract names & construct param array.
    nms = [nms; extra_params]
    parray = map(x -> hcat(x[1], x[2]), zip(vals_vec, extra_values_vec))
    parray = cat(parray..., dims=3)

    # Get the average or final log evidence, if it exists.
    le = getlogevidence(samples, state, spl)

    # Set up the info tuple.
    if save_state
        info = (model = model, sampler = spl, samplerstate = state)
    else
        info = NamedTuple()
    end

    # Concretize the array before giving it to MCMCChains.
    parray = MCMCChains.concretize(parray)

    # Chain construction.
    chain = MCMCChains.Chains(
        parray,
        nms,
        (internals = extra_params,);
        evidence=le,
        info=info,
        start=discard_initial + 1,
        thin=thinning,
    )

    return sort_chain ? sort(chain) : chain
end
