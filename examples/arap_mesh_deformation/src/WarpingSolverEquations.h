#pragma once

#include "../../shared/cudaUtil.h"

#include "WarpingSolverUtil.h"
#include "WarpingSolverState.h"
#include "WarpingSolverParameters.h"
#include "RotationHelper.h"

////////////////////////////////////////
// evalF
////////////////////////////////////////

__inline__ __device__ float evalFDevice(unsigned int variableIdx, SolverInput& input, SolverState& state, SolverParameters& parameters)
{

	float3 e = make_float3(0.0f, 0.0f, 0.0f);

	// E_fit
	if (state.d_target[variableIdx].x != MINF)
	{
		float3 e_fit = state.d_x[variableIdx] - state.d_target[variableIdx];
		e += parameters.weightFitting*e_fit*e_fit;
	}

	// E_reg
	float3	 e_reg = make_float3(0.0f, 0.0f, 0.0F);
	float3x3 R = evalR(state.d_a[variableIdx]);
	float3   p = state.d_x[variableIdx];
	float3   pHat = state.d_urshape[variableIdx];
	int numNeighbours = input.d_numNeighbours[variableIdx];
	for (unsigned int i = 0; i < numNeighbours; i++)
	{
		unsigned int neighbourIndex = input.d_neighbourIdx[input.d_neighbourOffset[variableIdx] + i];
		float3 q = state.d_x[neighbourIndex];
		float3 qHat = state.d_urshape[neighbourIndex];
		float3 d = (p - q) - R*(pHat - qHat);
		e_reg += d*d;
	}
	
	e += parameters.weightRegularizer*e_reg;
	
	float res = e.x + e.y + e.z;
	return res;
}

////////////////////////////////////////
// applyJT : this function is called per variable and evaluates each residual influencing that variable (i.e., each energy term per variable)
////////////////////////////////////////

__inline__ __device__ float3 evalMinusJTFDevice(unsigned int variableIdx, SolverInput& input, SolverState& state, SolverParameters& parameters, float3& outAngle)
{
	mat3x1 ones; ones(0) = 1.0f; ones(1) = 1.0f; ones(2) = 1.0f;

	state.d_delta [variableIdx]	= make_float3(0.0f, 0.0f, 0.0f);
	state.d_deltaA[variableIdx] = make_float3(0.0f, 0.0f, 0.0f);
	
	mat3x1 b;  b.setZero();
	mat3x1 bA; bA.setZero();

	mat3x1 pre; pre.setZero();
	mat3x3 preA; preA.setZero();
	
	mat3x1 p = mat3x1(state.d_x[variableIdx]);
	mat3x1 t = mat3x1(state.d_target[variableIdx]);
	// fit
	if (state.d_target[variableIdx].x != MINF)
	{
		b   -= 2.0f*parameters.weightFitting * (p - t);
		pre += 2.0f*parameters.weightFitting * ones;
	}
	
	mat3x1 e_reg; e_reg.setZero();
	mat3x1 e_reg_angle; e_reg_angle.setZero();

	mat3x1 pHat = mat3x1(state.d_urshape[variableIdx]);
	mat3x3 R_i = evalR(state.d_a[variableIdx]);
	mat3x3 dRAlpha, dRBeta, dRGamma;
	evalDerivativeRotationMatrix(state.d_a[variableIdx], dRAlpha, dRBeta, dRGamma);

	int numNeighbours = input.d_numNeighbours[variableIdx];
	for (unsigned int i = 0; i < numNeighbours; i++)
	{
		unsigned int neighbourIndex = input.d_neighbourIdx[input.d_neighbourOffset[variableIdx] + i];
	
		mat3x1 q	= mat3x1(state.d_x[neighbourIndex]);
		mat3x1 qHat = mat3x1(state.d_urshape[neighbourIndex]);
		mat3x3 R_j  = evalR(state.d_a[neighbourIndex]);
		mat3x3 D    = -evalDerivativeRotationTimesVector(dRAlpha, dRBeta, dRGamma, pHat - qHat);
		mat3x3 P	= parameters.weightRegularizer*D.getTranspose()*D;
		
		e_reg		+= 2.0f*(p - q) - (R_i+R_j)*(pHat - qHat);
		pre			+= 2.0f*(2.0f*parameters.weightRegularizer*ones);
		e_reg_angle += D.getTranspose()*((p - q) - R_i*(pHat - qHat));
		preA		+= 2.0f*P;
	}
	b  += -2.0f*parameters.weightRegularizer*e_reg;
	bA += -2.0f*parameters.weightRegularizer*e_reg_angle;


	//pre  = ones;		
	//preA.setIdentity(); 
	
	// pre-conditioner
	if (fabs(pre(0)) > FLOAT_EPSILON && fabs(pre(1)) > FLOAT_EPSILON && fabs(pre(2)) > FLOAT_EPSILON) { pre(0) = 1.0f/pre(0);  pre(1) = 1.0f/pre(1);  pre(2) = 1.0f/pre(2); } else { pre = ones; }
	state.d_precondioner[variableIdx] = make_float3(pre(0), pre(1), pre(2));

	//if (preA.det() > FLOAT_EPSILON) { preA = preA.getInverse(); } else { preA.setIdentity(); }
	//state.d_precondionerA[variableIdx] = make_float3(preA(0, 0), preA(1, 1), preA(2, 2));
	if (preA(0, 0) > FLOAT_EPSILON) {
		preA(0, 0) = 1.0f / preA(0, 0); 
		preA(1, 1) = 1.0f / preA(1, 1);
		preA(2, 2) = 1.0f / preA(2, 2);
	}
	else { 
		preA(0, 0) = 1.0f;
		preA(1, 1) = 1.0f;
		preA(2, 2) = 1.0f;
	}
	state.d_precondionerA[variableIdx] = make_float3(preA(0, 0), preA(1, 1), preA(2, 2));
		

	outAngle = bA;
	return b;
}

////////////////////////////////////////
// applyJTJ : this function is called per variable and evaluates each residual influencing that variable (i.e., each energy term per variable)
////////////////////////////////////////

__inline__ __device__ float3 applyJTJDevice(unsigned int variableIdx, SolverInput& input, SolverState& state, SolverParameters& parameters, float3& outAngle)
{
	mat3x1 b;  b.setZero();
	mat3x1 bA; bA.setZero();

	mat3x1 p = mat3x1(state.d_p[variableIdx]);

	// fit/pos
	if (state.d_target[variableIdx].x != MINF)
	{
		b += 2.0f*parameters.weightFitting*p;
	}
	
	// pos/reg
	mat3x1	e_reg; e_reg.setZero();
	mat3x1	e_reg_angle; e_reg_angle.setZero();
	
	mat3x3 dRAlpha, dRBeta, dRGamma;
	evalDerivativeRotationMatrix(state.d_a[variableIdx], dRAlpha, dRBeta, dRGamma);
	mat3x1 pHat = mat3x1(state.d_urshape[variableIdx]);
	mat3x1 pAngle = mat3x1(state.d_pA[variableIdx]);
	
	int numNeighbours = input.d_numNeighbours[variableIdx];
	for (unsigned int i = 0; i < numNeighbours; i++)
	{
		unsigned int neighbourIndex = input.d_neighbourIdx[input.d_neighbourOffset[variableIdx] + i];
		mat3x1 qHat = mat3x1(state.d_urshape[neighbourIndex]);
		mat3x3 D	= -evalDerivativeRotationTimesVector(dRAlpha, dRBeta, dRGamma, pHat - qHat);
		mat3x3 dRAlphaJ, dRBetaJ, dRGammaJ;
		evalDerivativeRotationMatrix(state.d_a[neighbourIndex], dRAlphaJ, dRBetaJ, dRGammaJ);
		mat3x3 D_j = -evalDerivativeRotationTimesVector(dRAlphaJ, dRBetaJ, dRGammaJ, pHat - qHat);
		mat3x1 q = mat3x1(state.d_p[neighbourIndex]);
		mat3x1 qAngle = mat3x1(state.d_pA[neighbourIndex]);

		e_reg		+= 2.0f*(p-q);
		e_reg_angle += D.getTranspose()*D*pAngle;
		e_reg		+= D*pAngle + D_j*qAngle;
		e_reg_angle += D.getTranspose()*(p - q);
	}
	b  += 2.0f*parameters.weightRegularizer*e_reg;
	bA += 2.0f*parameters.weightRegularizer*e_reg_angle;

	outAngle = bA;
	return b;
}
