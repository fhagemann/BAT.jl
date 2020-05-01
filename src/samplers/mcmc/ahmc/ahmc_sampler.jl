export AHMC

"""
@with_kw struct AHMC <: MCMCAlgorithm
    metric::HMCMetric = DiagEuclideanMetric()
    gradient::Module = ForwardDiff
    integrator::HMCIntegrator = Leapfrog()
    proposal::HMCProposal = NUTS()
    adaptor::HMCAdaptor = StanHMCAdaptor()
end


# Keyword arguments

Also see [AdvancedHMC.jl](https://github.com/TuringLang/AdvancedHMC.jl) for more detailed information on the following HMC related keyword arguments.
## Metric
options:
- `DiagEuclideanMetric()`
- `UnitEuclideanMetric()`
- `DenseEuclideanMetric()`

default: `metric = DiagEuclideanMetric()`

## Integrator
options:
- `LeapfrogIntegrator(step_size::Float64 = 0.0)`
- `JitteredLeapfrogIntegrator(step_size::Float64 = 0.0, jitter_rate::Float64 = 1.0)`
- `TemperedLEapfrogIntegrator(step_size::Float64 = 0.0, tempering_rate::Float64 = 1.05)`

default: `integrator = LeapfrogIntegrator(step_size::Float64 = 0.0)`
For `step_size = 0.0`, the initial stepsize is determined using `AdvancedHMC.find_good_stepsize()`


## Proposal
options:
- `FixedStepNumber(n_steps::Int64 = 10)`
- `FixedTrajectoryLength(trajectory_length::Float64 = 2.0)`
- `NUTS(sampling::Symbol, nuts::Symbol)`
with
    - `sampling =` `:SliceTS` or `:MultinomialTS`
    - `nuts = ` `:ClassicNoUTurn` or  `:GeneralisedNoUTUrn`

default: `proposal = NUTS(sampling::Symbol = :MultinomialTS, nuts::Symbol = :ClassicNoUTurn)`

## Adaptor
options:
- `MassMatrixAdaptor()`
- `StepSizeAdaptor(step_size::Float64 = 0.8)`
- `NaiveHMCAdaptor(step_size::Float64 = 0.8)`
- `StanHMCAdaptor(step_size::Float64 = 0.8)`

default: `adaptor =  StanHMCAdaptor(step_size::Float64 = 0.8)`
"""
@with_kw struct AHMC <: MCMCAlgorithm
    metric::HMCMetric = DiagEuclideanMetric()
    gradient::Module = ForwardDiff
    integrator::HMCIntegrator = Leapfrog()
    proposal::HMCProposal = NUTS()
    adaptor::HMCAdaptor = StanHMCAdaptor()
end


# MCMCSpec for AHMC
function (spec::MCMCSpec{<:AHMC})(
    rng::AbstractRNG,
    chainid::Integer
)
    P = Float64 # float(eltype(var_bounds(spec.posterior)))

    cycle = 0
    tuned = false
    converged = false
    info = MCMCIteratorInfo(chainid, cycle, tuned, converged)

    AHMCIterator(rng, spec, info, Vector{P}())
end



# MCMCIterator subtype for AHMC
mutable struct AHMCIterator{
    SP<:MCMCSpec,
    R<:AbstractRNG,
    PR<:RNGPartition,
    SV<:DensitySampleVector,
    I<:AdvancedHMC.AbstractIntegrator,
    P<:AdvancedHMC.AbstractProposal,
    A<:AdvancedHMC.AbstractAdaptor
} <: MCMCIterator
    spec::SP
    rng::R
    rngpart_cycle::PR
    info::MCMCIteratorInfo
    samples::SV
    nsamples::Int64
    stepno::Int64
    hamiltonian::AdvancedHMC.Hamiltonian
    transition::AdvancedHMC.Transition
    integrator::I
    proposal::P
    adaptor::A
end


function AHMCIterator(
    rng::AbstractRNG,
    spec::MCMCSpec,
    info::MCMCIteratorInfo,
    x_init::AbstractVector{P},
) where {P<:Real}
    stepno::Int64 = 0

    postr = spec.posterior
    npar = totalndof(postr)
    alg = spec.algorithm

    params_vec = Vector{P}(undef, npar)
    if isempty(x_init)
        mcmc_startval!(params_vec, rng, postr, alg)
    else
        params_vec .= x_init
    end
    !(params_vec in var_bounds(postr)) && throw(ArgumentError("Parameter(s) out of bounds"))

    log_posterior_value = apply_bounds_and_eval_posterior_logval_strict!(postr, params_vec)

    T = typeof(log_posterior_value)
    W = Float64 #_sample_weight_type(typeof(alg))

    sample_info = MCMCSampleID(info.id, info.cycle, 1, CURRENT_SAMPLE)
    current_sample = DensitySample(params_vec, log_posterior_value, one(W), sample_info, nothing)
    samples = DensitySampleVector{Vector{P},T,W,MCMCSampleID,Nothing}(undef, 0, npar)
    push!(samples, current_sample)

    nsamples::Int64 = 0

    rngpart_cycle = RNGPartition(rng, 0:(typemax(Int16) - 2))

    #TODO@C rename AHMC... functions
    metric = AHMCMetric(alg.metric, npar)
    logval_posterior(v) = density_logval(postr, v)

    hamiltonian = AdvancedHMC.Hamiltonian(metric, logval_posterior, alg.gradient)
    hamiltonian, t = AdvancedHMC.sample_init(rng, hamiltonian, params_vec)

    alg.integrator.step_size == 0.0 ? alg.integrator.step_size = AdvancedHMC.find_good_stepsize(hamiltonian, params_vec) : nothing
    ahmc_integrator = AHMCIntegrator(alg.integrator)

    ahmc_proposal = AHMCProposal(alg.proposal, ahmc_integrator)
    ahmc_adaptor = AHMCAdaptor(alg.adaptor, metric, ahmc_integrator)


    chain = AHMCIterator(
        spec,
        rng,
        rngpart_cycle,
        info,
        samples,
        nsamples,
        stepno,
        hamiltonian,
        t,
        ahmc_integrator,
        ahmc_proposal,
        ahmc_adaptor
    )

    reset_rng_counters!(chain)

    chain
end

mcmc_spec(chain::AHMCIterator) = chain.spec

getrng(chain::AHMCIterator) = chain.rng

mcmc_info(chain::AHMCIterator) = chain.info

nsteps(chain::AHMCIterator) = chain.stepno

nsamples(chain::AHMCIterator) = chain.nsamples

current_sample(chain::AHMCIterator) = chain.samples[_current_sample_idx(chain)]

sample_type(chain::AHMCIterator) = eltype(chain.samples)

@inline _current_sample_idx(chain::AHMCIterator) = firstindex(chain.samples)
@inline _proposed_sample_idx(chain::AHMCIterator) = lastindex(chain.samples)

function reset_rng_counters!(chain::AHMCIterator)
    set_rng!(chain.rng, chain.rngpart_cycle, chain.info.cycle)
    rngpart_step = RNGPartition(chain.rng, 0:(typemax(Int32) - 2))
    set_rng!(chain.rng, rngpart_step, chain.stepno)
    nothing
end


function samples_available(chain::AHMCIterator)
    i = _current_sample_idx(chain::AHMCIterator)
    chain.samples.info.sampletype[i] == ACCEPTED_SAMPLE
end


function _available_samples_idxs(chain::AHMCIterator)
    sampletype = chain.samples.info.sampletype
    @uviews sampletype begin
        from = firstindex(chain.samples)

        to = if samples_available(chain)
            lastidx = lastindex(chain.samples)
            @assert sampletype[from] == ACCEPTED_SAMPLE
            @assert sampletype[lastidx] == CURRENT_SAMPLE
            lastidx - 1
        else
            from - 1
        end

        r = from:to
        @assert all(x -> x > INVALID_SAMPLE, view(sampletype, r))
        r
    end
end


function get_samples!(appendable, chain::AHMCIterator, nonzero_weights::Bool)::typeof(appendable)
    if samples_available(chain)
        idxs = _available_samples_idxs(chain)
        samples = chain.samples

        @uviews samples begin
            # if nonzero_weights
                for i in idxs
                    if !nonzero_weights || samples.weight[i] > 0
                        push!(appendable, samples[i])
                    end
                end
            # else
            #     append!(appendable, view(samples, idxs))
            # end
        end
    end
    appendable
end


function next_cycle!(chain::AHMCIterator)
    chain.info = MCMCIteratorInfo(chain.info, cycle = chain.info.cycle + 1)
    chain.nsamples = 0
    chain.stepno = 0

    reset_rng_counters!(chain)

    resize!(chain.samples, 1)

    i = _current_sample_idx(chain)
    @assert chain.samples.info[i].sampletype == CURRENT_SAMPLE

    chain.samples.weight[i] = 1
    chain.samples.info[i] = MCMCSampleID(chain.info.id, chain.info.cycle, chain.stepno, CURRENT_SAMPLE)

    chain
end



AbstractMCMCTuningStrategy(algorithm::AHMC) = JustBurninTunerConfig()

function run_tuning_iterations!(
    callbacks,
    tuners::AbstractVector{<:NoOpTuner},
    chains::AbstractVector{<:AHMCIterator};
    max_nsamples::Int64 = Int64(1000),
    max_nsteps::Int64 = Int64(10000),
    max_time::Float64 = Inf
)
    user_callbacks = mcmc_callback_vector(callbacks, eachindex(chains))

    combined_callbacks = broadcast(tuners, user_callbacks) do tuner, user_callback
        (level, chain) -> begin
            if level == 1
                get_samples!(tuner.stats, chain, true)
            end
            user_callback(level, chain)
        end
    end

    mcmc_iterate!(combined_callbacks, chains, max_nsamples = max_nsamples, max_nsteps = max_nsteps, max_time = max_time)
    nothing
end

function run_tuning_cycle!(
    callbacks,
    tuners::AbstractVector{<:NoOpTuner},
    chains::AbstractVector{<:AHMCIterator};
    kwargs...
)
    run_tuning_iterations!(callbacks, tuners, chains; kwargs...)
    nothing
end

# just burnin no tuning
function mcmc_tune_burnin!(
    callbacks,
    tuners::AbstractVector{<:NoOpTuner},
    chains::AbstractVector{<:MCMCIterator},
    convergence_test::MCMCConvergenceTest,
    burnin_strategy::MCMCBurninStrategy;
    strict_mode::Bool = false
)
    @info "Begin burnin of $(length(tuners)) MCMC chain(s)."

    nchains = length(chains)

    user_callbacks = mcmc_callback_vector(callbacks, eachindex(chains))

    cycles = zero(Int)
    successful = false
    while !successful && cycles < burnin_strategy.max_ncycles
        cycles += 1
        run_tuning_cycle!(
            user_callbacks, tuners, chains;
            max_nsamples = burnin_strategy.max_nsamples_per_cycle,
            max_nsteps = burnin_strategy.max_nsteps_per_cycle,
            max_time = burnin_strategy.max_time_per_cycle
        )

        new_stats = [x.stats for x in tuners] # ToDo: Find more generic abstraction
        ct_result = check_convergence!(convergence_test, chains, new_stats)

        ntuned = count(c -> c.info.tuned, chains)
        nconverged = count(c -> c.info.converged, chains)
        successful = (nconverged == nchains)

        for i in eachindex(user_callbacks, tuners)
            user_callbacks[i](1, tuners[i])
        end

        @info "MCMC Tuning cycle $cycles finished, $nchains chains, $ntuned tuned, $nconverged converged."
    end

    if successful
        @info "MCMC tuning of $nchains chains successful after $cycles cycle(s)."
    else
        msg = "MCMC tuning of $nchains chains aborted after $cycles cycle(s)."
        if strict_mode
            @error msg
        else
            @warn msg
        end
    end

    successful
end








function mcmc_step!(
    callback::AbstractMCMCCallback,
    chain::AHMCIterator
)
    alg = algorithm(chain)
    #
    # if !mcmc_compatible(alg, chain.proposaldist, var_bounds(getposterior(chain)))
    #     error("Implementation of algorithm $alg does not support current parameter bounds with current proposal distribution")
    # end

    chain.stepno += 1
    reset_rng_counters!(chain)

    rng = getrng(chain)
    pstr = getposterior(chain)

    samples = chain.samples

    # Grow samples vector by one:
    resize!(samples, size(samples, 1) + 1)
    samples.info[lastindex(samples)] = MCMCSampleID(chain.info.id, chain.info.cycle, chain.stepno, PROPOSED_SAMPLE)

    current = _current_sample_idx(chain)
    proposed = _proposed_sample_idx(chain)
    @assert current != proposed

    accepted = @uviews samples begin
        current_params = samples.v[current]
        proposed_params = samples.v[proposed]

        # Propose new variate:
        samples.weight[proposed] = 0

        ahmc_step!(rng, alg, chain, proposed_params, current_params)

        current_log_posterior = samples.logd[current]
        T = typeof(current_log_posterior)

        # Evaluate prior and likelihood with proposed variate:
        proposed_log_posterior = apply_bounds_and_eval_posterior_logval!(T, pstr, proposed_params)

        samples.logd[proposed] = proposed_log_posterior


        samples.info.sampletype[current] = ACCEPTED_SAMPLE
        samples.info.sampletype[proposed] = CURRENT_SAMPLE
        chain.nsamples += 1


        delta_w_current, w_proposed = (0, 1) # always accepted
        samples.weight[current] += delta_w_current
        samples.weight[proposed] = w_proposed

        callback(1, chain)

        current_params .= proposed_params
        samples.logd[current] = samples.logd[proposed]
        samples.weight[current] = samples.weight[proposed]
        samples.info[current] = samples.info[proposed]

        true
    end # @uviews


    resize!(samples, 1)


    chain
end


function ahmc_step!(rng, alg, chain, proposed_params, current_params)
    chain.transition = AdvancedHMC.step(rng, chain.hamiltonian, chain.proposal, chain.transition.z)

    tstat = AdvancedHMC.stat(chain.transition)
    chain.hamiltonian, chain.proposal, isadapted = AdvancedHMC.adapt!(chain.hamiltonian, chain.proposal, chain.adaptor, 0, 1, chain.transition.z.θ, tstat.acceptance_rate)
    tstat = merge(tstat, (is_adapt=isadapted,))

    proposed_params[:] = chain.transition.z.θ
    nothing
end
