using Revise
using ADSeismic
using ADCME
using PyPlot
using MAT
using DelimitedFiles
using JLD2
using PyCall
matplotlib.use("Agg")
close("all")

ADCME.options.customop.verbose = false

py"""
import tensorflow as tf
config_proto = tf.ConfigProto(intra_op_parallelism_threads=0,
                              inter_op_parallelism_threads=0)
# from tensorflow.core.protobuf import rewriter_config_pb2
# off = rewriter_config_pb2.RewriterConfig.OFF
# config_proto.graph_options.rewrite_options.memory_optimization  = off
"""
config_proto = py"config_proto"
@show config_proto

#################################################################
output_dir = "data/elastic"
if !ispath(output_dir)
  mkpath(output_dir)
end

################### Generate synthetic data #####################
reset_default_graph()
mpi_init()

# model_name = "models/marmousi2-model-true-large.mat"
model_name = "models/marmousi2-model-true.mat"
# model_name = "models/BP-model-true.mat"

param = load_params(model_name, "MPIElastic")
compute_PML_Params!(param)

vp = matread(model_name)["vp"]
vs = matread(model_name)["vs"]
rho = matread(model_name)["rho"]

vp = extract_local_patch(param, vp)
vs = extract_local_patch(param, vs)
rho = extract_local_patch(param, rho)

λ, μ, ρ = compute_lame_parameters(vp, vs, rho)

# src = load_elastic_source(model_name, use_mpi=true, param=param)[4:4]
# receiver = load_elastic_receiver(model_name, use_mpi=true, param=param)[4:4]
# propagator = x->MPIElasticPropagatorSolver(param, x, ρ, λ, μ)
# [MPISimulatedObservation!(propagator(src[i]), receiver[i]) for i = 1:length(src)]
# Rs_ = [receiver[i].rcvv for i = 1:length(receiver)]

src = load_elastic_source(model_name, use_mpi=true, param=param)
receiver = load_elastic_receiver(model_name, use_mpi=true, param=param)

Rs_ = []
# for i = 1:length(src)
for i = 4:4
  src_ = src[i]
  receiver_ = receiver[i]

  propagator = MPIElasticPropagatorSolver(param, src_, ρ, λ, μ)
  MPISimulatedObservation!(propagator, receiver_)
  
  if (i < length(src)) && !ismissing(src[i+1].srcv) 
    src[i+1].srcv += sum(propagator.vx[end,:]) * 1e-20
  end

  push!(Rs_, receiver_.rcvv)
end

sess = Session(config=config_proto); init(sess)

@info "starting..."

@time Rs = run(sess, Rs_)
@info "saving..."
@save "data/data$(mpi_rank())-$(mpi_size()).jld2" Rs

# vx = run(sess, propagator(src[1]).vx)
# @info "saving..."
# @save "data/vx$(mpi_rank())-$(mpi_size()).jld2" vx

if mpi_rank()==0 && mpi_size()==1
  ii = 1 # source number
  u = run(sess, propagator(src[ii]).vx)
  p = visualize_wavefield(u, param)
  saveanim(p, "marmousi-wavefield.gif")
end

if mpi_size()>1
    mpi_finalize()  
end
