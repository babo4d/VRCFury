#include "sps_bezier.cginc"
#include "sps_light.cginc"
#include "sps_tri.cginc"
#include "sps_bake.cginc"
#include "sps_utils.cginc"

// SPS Penetration Shader
void sps_apply_real(inout float3 vertex, inout float3 normal, uint vertexId, inout float4 color)
{
	const float worldLength = _SPS_Length;
	const float3 origVertex = vertex;
	const float3 origNormal = normal;
	float3 bakedVertex;
	float3 bakedNormal;
	float active;
	SpsGetBakedPosition(vertexId, bakedVertex, bakedNormal, active);

	if (active == 0) return;

	float3 rootPos;
	bool isRing;
	float3 frontNormal;
	bool found = false;
	{
		sps_tri_GetData(Self, selfData)
		sps_tri_search(selfData, found, rootPos, isRing, frontNormal, color);
		sps_tri_GetData(Other, otherData)
		sps_tri_search(otherData, found, rootPos, isRing, frontNormal, color);
		sps_light_search(found, rootPos, isRing, frontNormal, color);
	}
	if (!found) return;

	float orfDistance = length(rootPos);
	float exitAngle = sps_angle_between(rootPos, float3(0,0,1));
	float entranceAngle = SPS_PI - sps_angle_between(frontNormal, rootPos);

	// Flip backward rings
	if (isRing && entranceAngle > SPS_PI/2) {
		frontNormal *= -1;
		entranceAngle = SPS_PI - entranceAngle;
	}

	// Decide if we should cancel deformation due to extreme angles, long distance, etc
	float bezierLerp;
	float dumbLerp;
	float shrinkLerp = 0;
	{
		float applyLerp = 1;
		// Cancel if base angle is too sharp
		const float allowedExitAngle = 0.6;
		const float exitAngleTooSharp = exitAngle > SPS_PI*allowedExitAngle ? 1 : 0;
		applyLerp = min(applyLerp, 1-exitAngleTooSharp);

		// Cancel if the entrance angle is too sharp
		if (!isRing) {
			const float allowedEntranceAngle = isRing ? 0.5 : 0.8;
			const float entranceAngleTooSharp = entranceAngle > SPS_PI*allowedEntranceAngle ? 1 : 0;
			applyLerp = min(applyLerp, 1-entranceAngleTooSharp);
		}
		
		if (!isRing) {
			// Uncancel if hilted in a hole
			const float hiltedSphereRadius = 0.3;
			const float inSphere = orfDistance > worldLength*hiltedSphereRadius ? 0 : 1;
			//const float hilted = min(isBehind, inSphere);
			//shrinkLerp = hilted;
			const float hilted = inSphere;
			applyLerp = max(applyLerp, hilted);
		} else {
			// Cancel if ring is near or behind base
			const float isBehind = rootPos.z > 0 ? 0 : 1;
			applyLerp = min(applyLerp, 1-isBehind);
		}

		// Cancel if too far away
		const float tooFar = sps_saturated_map(orfDistance, worldLength*1.2, worldLength*1.6);
		applyLerp = min(applyLerp, 1-tooFar);

		applyLerp = applyLerp * saturate(_SPS_Enabled);

		dumbLerp = sps_saturated_map(applyLerp, 0, 0.2) * active;
		bezierLerp = sps_saturated_map(applyLerp, 0, 1);
		shrinkLerp = sps_saturated_map(applyLerp, 0.8, 1) * shrinkLerp;
	}

	rootPos *= (1-shrinkLerp);
	orfDistance *= (1-shrinkLerp);

	float3 bezierPos;
	float3 bezierForward;
	float3 bezierRight;
	float3 bezierUp;
	float curveLength;
	if (length(rootPos) == 0) {
		bezierPos = float3(0,0,0);
		bezierForward = float3(0,0,1);
		bezierRight = float3(1,0,0);
		bezierUp = float3(0,1,0);
		curveLength = 0;
	} else{
		const float3 p0 = float3(0,0,0);
		const float p1Dist = min(orfDistance, max(worldLength / 8, rootPos.z / 4));
		const float p1DistWithPullout = sps_map(bezierLerp, 0, 1, worldLength * 5, p1Dist);
		const float3 p1 = float3(0,0,p1DistWithPullout);
		const float3 p2 = rootPos + frontNormal * p1Dist;
		const float3 p3 = rootPos;
		sps_bezierSolve(p0, p1, p2, p3, bakedVertex.z, curveLength, bezierPos, bezierForward, bezierUp);
		bezierRight = sps_normalize(cross(bezierUp, bezierForward));
	}

	// Handle holes and rings
	float holeShrink = 1;
	if (isRing) {
		if (bakedVertex.z >= curveLength) {
			// Straighten if past socket
			bezierPos += (bakedVertex.z - curveLength) * bezierForward;
		}
	} else {
		const float holeRecessDistance = worldLength * 0.05;
		const float holeRecessDistance2 = worldLength * 0.1;
		holeShrink = sps_saturated_map(
			bakedVertex.z,
			curveLength + holeRecessDistance2,
			curveLength + holeRecessDistance
		);
		if(_SPS_Overrun > 0) {
			if (bakedVertex.z >= curveLength + holeRecessDistance2) {
				// If way past socket, condense to point
				bezierPos += holeRecessDistance2 * bezierForward;
			} else if (bakedVertex.z >= curveLength) {
				// Straighten if past socket
				bezierPos += (bakedVertex.z - curveLength) * bezierForward;
			}
		}
	}

	float3 deformedVertex = bezierPos + bezierRight * bakedVertex.x * holeShrink + bezierUp * bakedVertex.y * holeShrink;
	float3 deformedNormal = bezierRight * bakedNormal.x + bezierUp * bakedNormal.y + bezierForward * bakedNormal.z;

	vertex = lerp(origVertex, deformedVertex, dumbLerp);
	normal = sps_normalize(lerp(origNormal, deformedNormal, dumbLerp)) * length(origNormal);
}
void sps_apply(inout float3 vertex, inout float3 normal, uint vertexId, inout float4 color) {
	// When VERTEXLIGHT_ON is missing, there are no lights nearby, and the 4light arrays will be full of junk
	// Temporarily disable this check since apparently it causes some passes to not apply SPS
	//#ifdef VERTEXLIGHT_ON
	sps_apply_real(vertex, normal, vertexId, color);
	//#endif
}
