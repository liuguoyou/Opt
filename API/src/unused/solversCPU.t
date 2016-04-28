
local S = require("std")
local util = require("util")
local C = util.C

solversCPU = {}

local kernels = {}

local makeCPUFunctions = function(problemSpec, vars, PlanData, kernels)
	local cpu = {}
	
	local data = {}
	data.problemSpec = problemSpec
	data.PlanData = PlanData
	data.imageType = problemSpec:UnknownType(false)
	
	cpu.computeCost = kernels.makeComputeCost(data)
	cpu.computeGradient = kernels.makeComputeGradient(data)
	
	return cpu
end

kernels.makeComputeCost = function(data)
	local terra computeCost(pd : &data.PlanData)
		var result = 0.0
		C.printf("computeCost\n")
		for h = 0, pd.parameters.X:H() do
			for w = 0, pd.parameters.X:W() do
				var v = data.problemSpec.functions.cost.boundary(w, h, w, h, pd.parameters)
				result = result + v
			end
		end
		return result
	end
	return computeCost
end

kernels.makeComputeGradient = function(data)
	local terra computeGradient(pd : &data.PlanData, gradientOut : data.imageType, values : data.imageType)
		var params = pd.parameters
		params.X = values
		for h = 0, gradientOut:H() do
			for w = 0, gradientOut:W() do
				gradientOut(w, h) = data.problemSpec.functions.gradient.boundary(w, h, w, h, params)
			end
		end
	end
	return computeGradient
end


solversCPU.gradientDescentCPU = function(problemSpec, vars)
	local struct PlanData(S.Object) {
		plan : opt.Plan
		parameters : problemSpec:ParameterType(false)	--get the non-blocked version
		
		gradient : problemSpec:UnknownType()
	}

	local cpu = makeCPUFunctions(problemSpec, vars, PlanData, kernels)
	
	local terra impl(data_ : &opaque, images : &&opaque, edgeValues : &&opaque, params_ : &&opaque)
		C.printf("Starting GD\n")
		var pd = [&PlanData](data_)
		
		--unpackstruct(pd.images) = [util.getImages(PlanData, images)]
		pd.parameters = [util.getParameters(problemSpec, images, edgeValues,params_)]

		-- TODO: parameterize these
		var initialLearningRate = 0.01
		var maxIters = 10000
		var tolerance = 1e-10

		-- Fixed constants (these do not need to be parameterized)
		var learningLoss = 0.8
		var learningGain = 1.1
		var minLearningRate = 1e-25

		var learningRate = initialLearningRate

		for iter = 0, maxIters do
			C.printf("Compute cost\n")
			var startCost = cpu.computeCost(pd)
			logSolver("iteration %d, cost=%f, learningRate=%f\n", iter, startCost, learningRate)
			--C.getchar()
			C.printf("Compute grad\n")
			cpu.computeGradient(pd, pd.gradient, pd.parameters.X)
			
			--
			-- move along the gradient by learningRate
			--
			var maxDelta = 0.0
			for h = 0, pd.parameters.X:H() do
				for w = 0, pd.parameters.X:W() do
					var delta = -learningRate * pd.gradient(w, h)
					pd.parameters.X(w, h) = pd.parameters.X(w, h) + delta
					maxDelta = util.max(C.fabsf(delta), maxDelta)
				end
			end
			C.printf("Compute cost\n")
			--
			-- update the learningRate
			--
			var endCost = cpu.computeCost(pd)
			if endCost < startCost then
				learningRate = learningRate * learningGain

				if maxDelta < tolerance then
					logSolver("terminating, maxDelta=%f\n", maxDelta)
					break
				end
			else
				learningRate = learningRate * learningLoss

				if learningRate < minLearningRate then
					logSolver("terminating, learningRate=%f\n", learningRate)
					break
				end
			end
		end
	end

	local terra makePlan() : &opt.Plan
		var pd = PlanData.alloc()
		pd.plan.data = pd
		pd.plan.impl = impl

		pd.gradient:initCPU()

		return &pd.plan
	end
	return makePlan
end

solversCPU.conjugateGradientCPU = function(problemSpec, vars)
	local struct PlanData(S.Object) {
		plan : opt.Plan
		parameters : problemSpec:ParameterType()
				
		currentValues : vars.unknownType
		currentResiduals : vars.unknownType
		
		gradient : vars.unknownType
		prevGradient : vars.unknownType
		
		searchDirection : vars.unknownType
	}
	
	local cpu = util.makeCPUFunctions(problemSpec, vars, PlanData)
	
	local terra impl(data_ : &opaque, images : &&opaque, params_ : &opaque)
		C.printf("Starting GD\n")
		var pd = [&PlanData](data_)
		var params = [&double](params_)

		unpackstruct(pd.images) = [util.getImages(PlanData, images)]
		
		var maxIters = 1000
		
		var prevBestAlpha = 0.0
		C.printf("Before iters")
		for iter = 0, maxIters do

			var iterStartCost = cpu.computeCost(pd)
			logSolver("iteration %d, cost=%f\n", iter, iterStartCost)
			C.printf("Compute cost")
			cpu.computeGradient(pd, pd.gradient, pd.parameters.X)
			C.printf("Compute grad")
			--
			-- compute the search direction
			--
			var beta = 0.0
			if iter == 0 then
				for h = 0, pd.parameters.X:H() do
					for w = 0, pd.parameters.X:W() do
						pd.searchDirection(w, h) = -pd.gradient(w, h)
					end
				end
			else
				var num = 0.0
				var den = 0.0
				
				--
				-- Polak-Ribiere conjugacy
				-- 
				for h = 0, pd.parameters.X:H() do
					for w = 0, pd.parameters.X:W() do
						var g = pd.gradient(w, h)
						var p = pd.prevGradient(w, h)
						num = num + (-g * (-g + p))
						den = den + p * p
					end
				end
				beta = util.max(num / den, 0.0)
				
				var epsilon = 1e-5
				if den > -epsilon and den < epsilon then
					beta = 0.0
				end
				
				for h = 0, pd.parameters.X:H() do
					for w = 0, pd.parameters.X:W() do
						pd.searchDirection(w, h) = -pd.gradient(w, h) + beta * pd.searchDirection(w, h)
					end
				end
			end
			
			cpu.copyImage(pd.prevGradient, pd.gradient)
			
			--
			-- line search
			--
			cpu.copyImage(pd.currentValues, pd.parameters.X)
			cpu.computeResiduals(pd, pd.currentValues, pd.currentResiduals)
			
			var bestAlpha, bestScore = cpu.lineSearchQuadraticFallback(pd, pd.currentValues, pd.currentResiduals, pd.searchDirection, pd.parameters.X, prevBestAlpha)
			
			for h = 0, pd.parameters.X:H() do
				for w = 0, pd.parameters.X:W() do
					pd.parameters.X(w, h) = pd.currentValues(w, h) + bestAlpha * pd.searchDirection(w, h)
				end
			end
			
			prevBestAlpha = bestAlpha
			
			logSolver("alpha=%12.12f, beta=%12.12f\n\n", bestAlpha, beta)
			if bestAlpha == 0.0 and beta == 0.0 then
				break
			end
		end
	end
	
	local terra makePlan() : &opt.Plan
		var pd = PlanData.alloc()
		pd.plan.data = pd
		pd.plan.impl = impl

		pd.currentValues:initCPU()
		
		pd.currentResiduals:initCPU()
		
		pd.gradient:initCPU()
		pd.prevGradient:initCPU()
		
		pd.searchDirection:initCPU()

		return &pd.plan
	end
	return makePlan
end

solversCPU.linearizedConjugateGradientCPU = function(problemSpec, vars)
	local struct PlanData(S.Object) {
		plan : opt.Plan
		parameters : problemSpec:ParameterType()
		
		b : vars.unknownType
		r : vars.unknownType
		p : vars.unknownType
		zeroes : vars.unknownType
		Ap : vars.unknownType
	}
	
	local cpu = util.makeCPUFunctions(problemSpec, vars, PlanData)

	local terra impl(data_ : &opaque, images : &&opaque, params_ : &opaque)
		var pd = [&PlanData](data_)
		var params = [&double](params_)

		unpackstruct(pd.images) = [util.getImages(PlanData, images)]
		
		-- TODO: parameterize these
		var maxIters = 1000
		var tolerance = 1e-5

		cpu.computeGradient(pd, pd.r, pd.parameters.X)
		cpu.scaleImage(pd.r, -1.0f)
		
		cpu.copyImage(pd.parameters.X, pd.zeroes)
		cpu.computeGradient(pd, pd.b, pd.parameters.X)
		
		cpu.copyImage(pd.p, pd.r)
		
		--for h = 0, pd.parameters.X:H() do
		--	for w = 0, pd.parameters.X:W() do
		--		pd.r(w, h) = -problemSpec.gradient.boundary(w, h, pd.parameters.X, vars.dataImages)
		--		pd.b(w, h) = problemSpec.gradient.boundary(w, h, pd.zeroes, vars.dataImages)
		--		pd.p(w, h) = pd.r(w, h)
		--	end
		--end
		
		var rTr = cpu.innerProduct(pd.r, pd.r)

		for iter = 0,maxIters do

			var iterStartCost = cpu.computeCost(pd)
			
			cpu.computeGradient(pd, pd.Ap, pd.p)
			cpu.addImage(pd.Ap, pd.b, -1.0f)
			
			--[[for h = 0, pd.parameters.X:H() do
				for w = 0, pd.parameters.X:W() do
					pd.Ap(w, h) = problemSpec.gradient.boundary(w, h, pd.p, vars.dataImages) - pd.b(w, h)
				end
			end]]
			
			var den = cpu.innerProduct(pd.p, pd.Ap)
			var alpha = rTr / den
			
			cpu.addImage(pd.parameters.X, pd.p, alpha)
			cpu.addImage(pd.r, pd.Ap, -alpha)
			
			--for h = 0, pd.parameters.X:H() do
			--	for w = 0, pd.parameters.X:W() do
			--		pd.parameters.X(w, h) = pd.parameters.X(w, h) + alpha * pd.p(w, h)
			--		pd.r(w, h) = pd.r(w, h) - alpha * pd.Ap(w, h)
			--	end
			--end
			
			var rTrNew = cpu.innerProduct(pd.r, pd.r)
			
			logSolver("iteration %d, cost=%f, rTr=%f\n", iter, iterStartCost, rTrNew)
			
			if(rTrNew < tolerance) then break end
			
			var beta = rTrNew / rTr
			
			for h = 0, pd.parameters.X:H() do
				for w = 0, pd.parameters.X:W() do
					pd.p(w, h) = pd.r(w, h) + beta * pd.p(w, h)
				end
			end
			
			rTr = rTrNew
		end
		
		var finalCost = cpu.computeCost(pd)
		logSolver("final cost=%f\n", finalCost)
	end

	local terra makePlan() : &opt.Plan
		var pd = PlanData.alloc()
		pd.plan.data = pd
		pd.plan.impl = impl

		pd.b:initCPU()
		pd.r:initCPU()
		pd.p:initCPU()
		pd.Ap:initCPU()
		pd.zeroes:initCPU()
		
		return &pd.plan
	end
	return makePlan
end

solversCPU.lbfgsCPU = function(problemSpec, vars)

	local maxIters = 1000
	
	local struct PlanData(S.Object) {
		plan : opt.Plan
		parameters : problemSpec:ParameterType()
		
		gradient : vars.unknownType
		prevGradient : vars.unknownType
				
		p : vars.unknownType
		sList : vars.unknownType[maxIters]
		yList : vars.unknownType[maxIters]
		syProduct : float[maxIters]
		yyProduct : float[maxIters]
		alphaList : float[maxIters]
		
		-- variables used for line search
		currentValues : vars.unknownType
		currentResiduals : vars.unknownType
	}
	
	local cpu = util.makeCPUFunctions(problemSpec, vars, PlanData)
	
	local terra impl(data_ : &opaque, images : &&opaque, params_ : &opaque)

		-- two-loop recursion: http://papers.nips.cc/paper/5333-large-scale-l-bfgs-using-mapreduce.pdf
		
		var pd = [&PlanData](data_)
		var params = [&double](params_)

		unpackstruct(pd.images) = [util.getImages(PlanData, images)]

		var m = 2
		var k = 0
		
		var prevBestAlpha = 0.0
		
		cpu.computeGradient(pd, pd.gradient, pd.parameters.X)

		for iter = 0, maxIters - 1 do

			var iterStartCost = cpu.computeCost(pd)
			logSolver("iteration %d, cost=%f\n", iter, iterStartCost)
			
			--
			-- compute the search direction p
			--
			cpu.setImage(pd.p, pd.gradient, -1.0f)
			
			if k >= 1 then
				for i = k - 1, k - m - 1, -1 do
					if i < 0 then break end
					pd.alphaList[i] = cpu.innerProduct(pd.sList[i], pd.p) / pd.syProduct[i]
					cpu.addImage(pd.p, pd.yList[i], -pd.alphaList[i])
				end
				var scale = pd.syProduct[k - 1] / pd.yyProduct[k - 1]
				cpu.scaleImage(pd.p, scale)
				for i = k - m, k do
					if i >= 0 then
						var beta = cpu.innerProduct(pd.yList[i], pd.p) / pd.syProduct[i]
						cpu.addImage(pd.p, pd.sList[i], pd.alphaList[i] - beta)
					end
				end
			end
			
			--
			-- line search
			--
			cpu.copyImage(pd.currentValues, pd.parameters.X)
			cpu.computeResiduals(pd, pd.currentValues, pd.currentResiduals)
			
			var bestAlpha, bestScore = cpu.lineSearchQuadraticFallback(pd, pd.currentValues, pd.currentResiduals, pd.p, pd.parameters.X, prevBestAlpha)
			
			-- compute new x and s
			for h = 0, pd.parameters.X:H() do
				for w = 0, pd.parameters.X:W() do
					var delta = bestAlpha * pd.p(w, h)
					pd.parameters.X(w, h) = pd.currentValues(w, h) + delta
					pd.sList[k](w, h) = delta
				end
			end
			
			cpu.copyImage(pd.prevGradient, pd.gradient)
			
			cpu.computeGradient(pd, pd.gradient, pd.parameters.X)
			
			-- compute new y
			for h = 0, pd.parameters.X:H() do
				for w = 0, pd.parameters.X:W() do
					pd.yList[k](w, h) = pd.gradient(w, h) - pd.prevGradient(w, h)
				end
			end
			
			pd.syProduct[k] = cpu.innerProduct(pd.sList[k], pd.yList[k])
			pd.yyProduct[k] = cpu.innerProduct(pd.yList[k], pd.yList[k])
			
			prevBestAlpha = bestAlpha
			
			k = k + 1
			
			logSolver("alpha=%12.12f\n\n", bestAlpha)
			if bestAlpha == 0.0 then
				break
			end
		end
	end
	
	local terra makePlan() : &opt.Plan
		var pd = PlanData.alloc()
		pd.plan.data = pd
		pd.plan.impl = impl
		
		pd.gradient:initCPU()
		pd.prevGradient:initCPU()
		
		pd.currentValues:initCPU()
		pd.currentResiduals:initCPU()
		
		pd.p:initCPU()
		
		for i = 0, maxIters - 1 do
			pd.sList[i]:initCPU()
			pd.yList[i]:initCPU()
		end

		return &pd.plan
	end
	return makePlan
end

-- vector-free L-BFGS using two-loop recursion: http://papers.nips.cc/paper/5333-large-scale-l-bfgs-using-mapreduce.pdf
solversCPU.vlbfgsCPU = function(problemSpec, vars)

	local maxIters = 1000
	local m = 2
	local b = 2 * m + 1
	
	--TODO: how do I do this correctly?
	--local bDim = opt.Dim("b", b )
	--opt.InternalImage(float, bDim, bDim)
	
	local struct PlanData(S.Object) {
		plan : opt.Plan
		parameters : problemSpec:ParameterType()
		
		gradient : vars.unknownType
		prevGradient : vars.unknownType

		p : vars.unknownType
		sList : vars.unknownType[m]
		yList : vars.unknownType[m]
		alphaList : float[maxIters]
		
		dotProductMatrix : vars.unknownType
		dotProductMatrixStorage : vars.unknownType
		coefficients : double[b]
		
		-- variables used for line search
		currentValues : vars.unknownType
		currentResiduals : vars.unknownType
	}
	
	local terra imageFromIndex(pd : &PlanData, index : int)
		if index < m then
			return pd.sList[index]
		elseif index < 2 * m then
			return pd.yList[index - m]
		else
			return pd.gradient
		end
	end
	
	local terra nextCoefficientIndex(index : int)
		if index == m - 1 or index == 2 * m - 1 or index == 2 * m then
			return -1
		end
		return index + 1
	end
	
	local cpu = util.makeCPUFunctions(problemSpec, vars, PlanData)
	
	local terra impl(data_ : &opaque, images : &&opaque, params_ : &opaque)
		
		var pd = [&PlanData](data_)
		var params = [&double](params_)

		unpackstruct(pd.images) = [util.getImages(PlanData, images)]

		var k = 0
		
		-- using an initial guess of alpha means that it will invoke quadratic optimization on the first iteration,
		-- which is only sometimes a good idea.
		var prevBestAlpha = 1.0
		
		cpu.computeGradient(pd, pd.gradient, pd.parameters.X)

		for iter = 0, maxIters - 1 do

			var iterStartCost = cpu.computeCost(pd)
			logSolver("iteration %d, cost=%f\n", iter, iterStartCost)
			
			--
			-- compute the search direction p
			--
			if k == 0 then
				cpu.setImage(pd.p, pd.gradient, -1.0f)
			else
				-- compute the top half of the dot product matrix
				cpu.copyImage(pd.dotProductMatrixStorage, pd.dotProductMatrix)
				for i = 0, b do
					for j = i, b do
						var prevI = nextCoefficientIndex(i)
						var prevJ = nextCoefficientIndex(j)
						if prevI == -1 or prevJ == -1 then
							pd.dotProductMatrix(i, j) = cpu.innerProduct(imageFromIndex(pd, i), imageFromIndex(pd, j))
						else
							pd.dotProductMatrix(i, j) = pd.dotProductMatrixStorage(prevI, prevJ)
						end
					end
				end
				
				-- compute the bottom half of the dot product matrix
				for i = 0, b do
					for j = 0, i do
						pd.dotProductMatrix(i, j) = pd.dotProductMatrix(j, i)
					end
				end
			
				for i = 0, 2 * m do pd.coefficients[i] = 0.0 end
				pd.coefficients[2 * m] = -1.0
				
				for i = k - 1, k - m - 1, -1 do
					if i < 0 then break end
					var j = i - (k - m)
					
					var num = 0.0
					for q = 0, b do
						num = num + pd.coefficients[q] * pd.dotProductMatrix(q, j)
					end
					var den = pd.dotProductMatrix(j, j + m)
					pd.alphaList[i] = num / den
					pd.coefficients[j + m] = pd.coefficients[j + m] - pd.alphaList[i]
				end
				
				var scale = pd.dotProductMatrix(m - 1, 2 * m - 1) / pd.dotProductMatrix(2 * m - 1, 2 * m - 1)
				for i = 0, b do
					pd.coefficients[i] = pd.coefficients[i] * scale
				end
				
				for i = k - m, k do
					if i >= 0 then
						var j = i - (k - m)
						var num = 0.0
						for q = 0, b do
							num = num + pd.coefficients[q] * pd.dotProductMatrix(q, m + j)
						end
						var den = pd.dotProductMatrix(j, j + m)
						var beta = num / den
						pd.coefficients[j] = pd.coefficients[j] + (pd.alphaList[i] - beta)
					end
				end
				
				--
				-- reconstruct p from basis vectors
				--
				cpu.scaleImage(pd.p, 0.0f)
				for i = 0, b do
					var image = imageFromIndex(pd, i)
					var coefficient = pd.coefficients[i]
					cpu.addImage(pd.p, image, coefficient)
				end
			end
			
			--
			-- line search
			--
			cpu.copyImage(pd.currentValues, pd.parameters.X)
			cpu.computeResiduals(pd, pd.currentValues, pd.currentResiduals)
			
			var bestAlpha, bestScore = cpu.lineSearchQuadraticFallback(pd, pd.currentValues, pd.currentResiduals, pd.p, pd.parameters.X, prevBestAlpha)
			
			-- cycle the oldest s and y
			var yListStore = pd.yList[0]
			var sListStore = pd.sList[0]
			for i = 0, m - 1 do
				pd.yList[i] = pd.yList[i + 1]
				pd.sList[i] = pd.sList[i + 1]
			end
			pd.yList[m - 1] = yListStore
			pd.sList[m - 1] = sListStore
			
			-- compute new x and s
			for h = 0, pd.parameters.X:H() do
				for w = 0, pd.parameters.X:W() do
					var delta = bestAlpha * pd.p(w, h)
					pd.parameters.X(w, h) = pd.currentValues(w, h) + delta
					pd.sList[m - 1](w, h) = delta
				end
			end
			
			cpu.copyImage(pd.prevGradient, pd.gradient)
			
			cpu.computeGradient(pd, pd.gradient, pd.parameters.X)
			
			-- compute new y
			for h = 0, pd.parameters.X:H() do
				for w = 0, pd.parameters.X:W() do
					pd.yList[m - 1](w, h) = pd.gradient(w, h) - pd.prevGradient(w, h)
				end
			end
			
			prevBestAlpha = bestAlpha
			
			k = k + 1
			
			logSolver("alpha=%12.12f\n\n", bestAlpha)
			if bestAlpha == 0.0 then
				break
			end
		end
	end
	
	local terra makePlan() : &opt.Plan
		var pd = PlanData.alloc()
		pd.plan.data = pd
		pd.plan.impl = impl

		pd.gradient:initCPU()
		pd.prevGradient:initCPU()
		
		pd.currentValues:initCPU()
		pd.currentResiduals:initCPU()
		
		pd.p:initCPU()
		
		for i = 0, m do
			pd.sList[i]:initCPU()
			pd.yList[i]:initCPU()
		end
		
		pd.dotProductMatrix:initCPU()
		pd.dotProductMatrixStorage:initCPU()

		return &pd.plan
	end
	return makePlan
end

-- vector-free L-BFGS using two-loop recursion: http://papers.nips.cc/paper/5333-large-scale-l-bfgs-using-mapreduce.pdf
solversCPU.bidirectionalVLBFGSCPU = function(problemSpec, vars)

	local maxIters = 1000
	local m = 4
	local b = 2 * m + 1
	
	local struct PlanData(S.Object) {
		plan : opt.Plan
		parameters : problemSpec:ParameterType()
		
		gradient : vars.unknownType
		prevGradient : vars.unknownType

		p : vars.unknownType
		biSearchDirection : vars.unknownType
		sList : vars.unknownType[m]
		yList : vars.unknownType[m]
		alphaList : float[maxIters]
		
		dotProductMatrix : vars.unknownType
		dotProductMatrixStorage : vars.unknownType
		coefficients : double[b]
		
		-- variables used for line search
		currentValues : vars.unknownType
		currentResiduals : vars.unknownType
	}
	
	local terra imageFromIndex(pd : &PlanData, index : int)
		if index < m then
			return pd.sList[index]
		elseif index < 2 * m then
			return pd.yList[index - m]
		else
			return pd.gradient
		end
	end
	
	local terra nextCoefficientIndex(index : int)
		if index == m - 1 or index == 2 * m - 1 or index == 2 * m then
			return -1
		end
		return index + 1
	end
	
	local cpu = util.makeCPUFunctions(problemSpec, vars, PlanData)
	
	local terra impl(data_ : &opaque, images : &&opaque, params_ : &opaque)
		
		var file = C.fopen("C:/code/run.txt", "wb")
		
		var pd = [&PlanData](data_)
		var params = [&double](params_)

		unpackstruct(pd.images) = [util.getImages(PlanData, images)]

		var k = 0
		
		-- using an initial guess of alpha means that it will invoke quadratic optimization on the first iteration,
		-- which is only sometimes a good idea.
		var prevBestSearch = 0.0
		
		cpu.computeGradient(pd, pd.gradient, pd.parameters.X)
		
		cpu.clearImage(pd.biSearchDirection, 1.0f)

		for iter = 0, maxIters - 1 do
		--for iter = 0, 10 do

			var iterStartCost = cpu.computeCost(pd)
			logSolver("iteration %d, cost=%f\n", iter, iterStartCost)
			
			C.fprintf(file, "%d\t%15.15f\n", iter, iterStartCost)
			
			--
			-- compute the search direction p
			--
			if k == 0 then
				cpu.setImage(pd.p, pd.gradient, -1.0f)
			else
				-- compute the top half of the dot product matrix
				cpu.copyImage(pd.dotProductMatrixStorage, pd.dotProductMatrix)
				for i = 0, b do
					for j = i, b do
						var prevI = nextCoefficientIndex(i)
						var prevJ = nextCoefficientIndex(j)
						if prevI == -1 or prevJ == -1 then
							pd.dotProductMatrix(i, j) = cpu.innerProduct(imageFromIndex(pd, i), imageFromIndex(pd, j))
						else
							pd.dotProductMatrix(i, j) = pd.dotProductMatrixStorage(prevI, prevJ)
						end
					end
				end
				
				-- compute the bottom half of the dot product matrix
				for i = 0, b do
					for j = 0, i do
						pd.dotProductMatrix(i, j) = pd.dotProductMatrix(j, i)
					end
				end
			
				for i = 0, 2 * m do pd.coefficients[i] = 0.0 end
				pd.coefficients[2 * m] = -1.0
				
				for i = k - 1, k - m - 1, -1 do
					if i < 0 then break end
					var j = i - (k - m)
					
					var num = 0.0
					for q = 0, b do
						num = num + pd.coefficients[q] * pd.dotProductMatrix(q, j)
					end
					var den = pd.dotProductMatrix(j, j + m)
					pd.alphaList[i] = num / den
					pd.coefficients[j + m] = pd.coefficients[j + m] - pd.alphaList[i]
				end
				
				var scale = pd.dotProductMatrix(m - 1, 2 * m - 1) / pd.dotProductMatrix(2 * m - 1, 2 * m - 1)
				for i = 0, b do
					pd.coefficients[i] = pd.coefficients[i] * scale
				end
				
				for i = k - m, k do
					if i >= 0 then
						var j = i - (k - m)
						var num = 0.0
						for q = 0, b do
							num = num + pd.coefficients[q] * pd.dotProductMatrix(q, m + j)
						end
						var den = pd.dotProductMatrix(j, j + m)
						var beta = num / den
						pd.coefficients[j] = pd.coefficients[j] + (pd.alphaList[i] - beta)
					end
				end
				
				--
				-- reconstruct p from basis vectors
				--
				cpu.scaleImage(pd.p, 0.0f)
				for i = 0, b do
					var image = imageFromIndex(pd, i)
					var coefficient = pd.coefficients[i]
					cpu.addImage(pd.p, image, coefficient)
				end
			end
			
			-- bisearch direction should be orthogonal to p (the bfgs search direction).  Achieve this using Gram–Schmidt.
			var pp = cpu.innerProduct(pd.p, pd.p)
			var bp = cpu.innerProduct(pd.biSearchDirection, pd.p)
			var biScaleA = -bp / pp
			cpu.addImage(pd.biSearchDirection, pd.biSearchDirection, biScaleA)
			
			-- bisearch direction should be a weighted average of gradients
			--cpu.copyImage(pd.biSearchDirection, pd.gradient)
			
			-- bisearch should be the same scale as p, and point in the same direction as the negative gradient
			var biScaleB = C.sqrtf(pp) / C.sqrtf(cpu.innerProduct(pd.biSearchDirection, pd.biSearchDirection))
			var biSearchGrad = cpu.innerProduct(pd.biSearchDirection, pd.gradient)
			if biSearchGrad > 0.0f then biScaleB = biScaleB * -1.0f end
			cpu.scaleImage(pd.biSearchDirection, biScaleB)
			
			-- line search
			cpu.copyImage(pd.currentValues, pd.parameters.X)
			cpu.computeResiduals(pd, pd.currentValues, pd.currentResiduals)
			
			var bestAlpha = 0.0f
			var bestBeta = 0.0f
			var bestScore = 0.0f
			
			if iter == 0 then
				bestAlpha, bestScore = cpu.lineSearchQuadraticFallback(pd, pd.currentValues, pd.currentResiduals, pd.p, pd.parameters.X, prevBestSearch)
			else
				bestAlpha, bestBeta = cpu.biLineSearch(pd, pd.currentValues, pd.currentResiduals, pd.p, pd.biSearchDirection, prevBestSearch, prevBestSearch, pd.parameters.X)
			end
			
			--bestAlpha, bestScore = cpu.lineSearchQuadraticFallback(pd, pd.currentValues, pd.currentResiduals, pd.p, pd.parameters.X, prevBestSearch)
			--bestBeta = 0.0f
			
			if iter == 1 then
				cpu.dumpBiLineSearch(pd, pd.currentValues, pd.currentResiduals, pd.p, pd.biSearchDirection, pd.parameters.X)
				--cpu.dumpLineSearch(pd, pd.currentValues, pd.currentResiduals, pd.biSearchDirection, pd.parameters.X)
			end
			
			
			
			-- cycle the oldest s and y
			var yListStore = pd.yList[0]
			var sListStore = pd.sList[0]
			for i = 0, m - 1 do
				pd.yList[i] = pd.yList[i + 1]
				pd.sList[i] = pd.sList[i + 1]
			end
			pd.yList[m - 1] = yListStore
			pd.sList[m - 1] = sListStore
			
			-- compute new x and s
			for h = 0, pd.parameters.X:H() do
				for w = 0, pd.parameters.X:W() do
					var delta = bestAlpha * pd.p(w, h) + bestBeta * pd.biSearchDirection(w, h)
					pd.parameters.X(w, h) = pd.currentValues(w, h) + delta
					pd.sList[m - 1](w, h) = delta
				end
			end
			
			cpu.copyImage(pd.prevGradient, pd.gradient)
			
			cpu.computeGradient(pd, pd.gradient, pd.parameters.X)
			
			-- compute new y
			for h = 0, pd.parameters.X:H() do
				for w = 0, pd.parameters.X:W() do
					pd.yList[m - 1](w, h) = pd.gradient(w, h) - pd.prevGradient(w, h)
				end
			end
			
			prevBestSearch = util.max(bestAlpha, bestBeta)
			
			--if prevBestSearch >= 1.0 then prevBestSearch = 1.0 end
						
			k = k + 1
			
			logSolver("alpha=%12.12f, beta=%12.12f\n\n", bestAlpha, bestBeta)
			if prevBestSearch == 0.0 then
				break
			end
			
			if bestAlpha == 0.0 then
				logSolver("alpha failed -- resetting")
				k = 0
				prevBestSearch = 0.0
			end
		end
		
		C.fclose(file)
	end
	
	local terra makePlan() : &opt.Plan
		var pd = PlanData.alloc()
		pd.plan.data = pd
		pd.plan.impl = impl

		pd.gradient:initCPU()
		pd.prevGradient:initCPU()
		
		pd.currentValues:initCPU()
		pd.currentResiduals:initCPU()
		
		pd.p:initCPU()
		
		for i = 0, m do
			pd.sList[i]:initCPU()
			pd.yList[i]:initCPU()
		end
		
		pd.dotProductMatrix:initCPU()
		pd.dotProductMatrixStorage:initCPU()
		
		pd.biSearchDirection:initCPU()

		return &pd.plan
	end
	return makePlan
end

return solversCPU