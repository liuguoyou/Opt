#pragma once

#include <cuda_runtime.h>

#include "cudaUtil.h"
#include "WarpingSolverParameters.h"
#include "WarpingSolverState.h"

#include "../../shared/Precision.h"

class CERESWarpingSolver
{
	public:
		CERESWarpingSolver(unsigned int N);
		~CERESWarpingSolver();

		void solve(int3 dims, float3* d_vertexPosFloat3, float3* d_anglesFloat3, float3* d_vertexPosFloat3Urshape, float3* d_vertexPosTargetFloat3, int nonLinearIter, int linearIter, float weightFit, float weightReg);
		
	private:

		SolverState	m_solverState;

		unsigned int m_N;
};
